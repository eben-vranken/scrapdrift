extends Node2D

## Temporary test harness: fixed camera, a generated track, and one to four cars
## racing it. Press respawn to put the field back on the start line.
##
## Everything that belongs to a single car is spawned here, per player, rather
## than sitting in the scene: the car itself, its rubber, its drift score, the
## wreckage it leaves and the text thrown off it. The scene only holds the layers
## they go into, which is what keeps the draw order right no matter how many
## players there are: rubber under the cars, wreckage and popups over them.
##
## The camera frames the whole circuit at once, which is the reason couch co-op
## needs nothing else from the view. There is no split screen because there is
## nothing to split; everybody is already looking at the same picture.
##
## What the field is comes from PlayerConfig, filled in by the menu. Run this
## scene on its own and it falls back to one keyboard player, so testing a track
## change does not mean going through the lobby every time.

const CarScene := preload("res://scenes/car.tscn")
const CarScript := preload("res://scripts/car.gd")
const ScoreScript := preload("res://scripts/drift_score.gd")
const PopupsScript := preload("res://scripts/drift_popups.gd")
const SkidScript := preload("res://scripts/skid_marks.gd")
const LapSystemScript := preload("res://scripts/lap_system.gd")
const ExplosionScript := preload("res://scripts/explosion.gd")

@onready var track := $Track
@onready var skid_layer := $SkidLayer
@onready var cars_root := $Cars
@onready var scores_root := $Scores
@onready var effects_root := $Effects
@onready var popups_root := $Popups
@onready var lap_system: LapSystemScript = $LapSystem
@onready var transition := $ScreenTransition
@onready var readout: Label = $HUD/Readout
@onready var score_readout: Label = $HUD/Score
@onready var board: VBoxContainer = $HUD/PlayerBoard

## How long the field coasts, uncontrolled, between the win and the wipe
## starting. Long enough to watch the run land; short enough not to drag.
const FINISH_RIDE_TIME := 1.0

## How long a wreck lies there before that player is put back on the line. The
## crash is the punishment, and an instant respawn hands the car back before the
## player has registered losing it: the pause is what makes a wall tap land as a
## mistake rather than a stutter. Long enough for the blast to play out, short
## enough that the other three are not left waiting on it.
const RESPAWN_DELAY := 1.1

## The starting grid, in the spawn transform's own space: x runs down the track,
## y across it. Two by two, far enough apart that nobody spawns inside anybody
## and narrow enough to stay well inside the corridor. Cars pass through each
## other, so this is only about being able to see whose car is whose at the
## lights; nothing is being kept out of anything.
const GRID_OFFSETS: Array[Vector2] = [
	Vector2(0.0, -16.0),
	Vector2(0.0, 16.0),
	Vector2(-30.0, -16.0),
	Vector2(-30.0, 16.0),
]

## Total rubber on the asphalt, shared out across the field. A per-car budget
## would quadruple the line count with four players for no extra readability.
const SKID_BUDGET := 192

var spawn_point: Transform2D
## True from the win until the new track is fully revealed. Covers both the
## coasting second and the wipe, and is what locks out player input and keeps a
## car that dies in that window dead.
var _finishing := false

var cars: Array[CarScript] = []
var scores: Array[ScoreScript] = []
var _skids: Array[SkidScript] = []
## Each player's paint, in grid order. Kept because the wreckage is thrown in it,
## and a car that has already blown up is no longer showing what colour it was.
var _colors: Array[Color] = []
## One line of the lap board per player, in grid order.
var _lines: Array[Label] = []
## A crowd, rather than one player with the screen to themselves. Decides which
## HUD is shown: the single big score, or a line per player.
var _coop := false


func _ready() -> void:
	PlayerConfig.ensure_players()
	# Bound here rather than trusting whatever the menu left in the InputMap, so
	# reloading this scene re-binds instead of racing on a stale map.
	PlayerConfig.apply_input_map()
	_coop = PlayerConfig.players.size() > 1

	# Track builds itself in its own _ready, which runs before this one.
	spawn_point = track.get_spawn()
	_build_field()

	# Every rebuild, not just the one below, so this keeps holding once the track
	# starts regenerating on its own every few laps.
	track.rebuilt.connect(_clear_rubber)

	lap_system.set_cars(cars)
	lap_system.race_won.connect(_on_race_won)
	lap_system.checkpoint_passed.connect(_on_lap_progress)
	lap_system.lap_completed.connect(_on_lap_progress)
	lap_system.lap_completed.connect(_on_lap_finished)
	track.rebuilt.connect(_on_lap_progress)
	# The swap happens while the wipe has the screen fully black, never in view.
	transition.covered.connect(_swap_track)
	transition.finished.connect(_on_transition_finished)
	_refresh_board()


func _process(_delta: float) -> void:
	# The speed line reads one car, so it only means anything when there is one
	# car. In co-op each player's line on the board carries their own numbers.
	if not readout.visible:
		return
	var car := cars[0]
	var state := "DRIFT" if car.is_drifting else "GRIP"
	readout.text = "%3d km/h  %s" % [roundi(absf(car.speed) * 1.35), state]


func _unhandled_input(event: InputEvent) -> void:
	# From the win through the coasting second and the wipe, the race is out of
	# the players' hands; swallow respawn and regenerate until it is back.
	if _finishing:
		return
	# Both of these act on the whole session rather than on one car: respawn
	# throws the entire field back to the line and regenerate rebuilds the track
	# under it. Bound to player one alone, so three friends on pads cannot reset
	# a race the fourth is winning.
	if event.is_action_pressed(PlayerConfig.debug_action("respawn")):
		_reset_field()
		lap_system.reset_all_progress()
	elif event.is_action_pressed(PlayerConfig.debug_action("regenerate")):
		track.generate()
		spawn_point = track.get_spawn()
		_reset_field()


## Spawns a car per player and everything that hangs off one. Order matters in
## two places: the car has to be in the tree before it can be painted, and the
## score and popups have to be handed their car before they enter the tree,
## since that is when they wire themselves to it.
func _build_field() -> void:
	# The single big score and the speed line are a one-player HUD. With a crowd
	# they would each be showing one arbitrary player's numbers, so the board
	# takes over and these go away.
	readout.visible = not _coop
	score_readout.visible = not _coop
	if not _coop:
		# Controls scale out of their top-left corner unless told otherwise, which
		# would make the punch throw the number sideways instead of swelling it
		# in place.
		score_readout.pivot_offset = score_readout.size * 0.5

	var count := PlayerConfig.players.size()
	for slot in count:
		var entry: Dictionary = PlayerConfig.players[slot]
		var color: Color = PlayerConfig.color_of(entry["color"])

		var car: CarScript = CarScene.instantiate()
		car.action_prefix = PlayerConfig.prefix_for(slot)
		car.device = entry["device"]
		cars_root.add_child(car)
		car.paint(color)
		car.reset(_grid_slot(slot))
		car.crashed.connect(_on_car_crashed.bind(slot))
		cars.append(car)
		_colors.append(color)

		var skids := SkidScript.new()
		skids.car = car
		skids.max_marks = maxi(SKID_BUDGET / count, 48)
		skid_layer.add_child(skids)
		_skids.append(skids)

		var score := ScoreScript.new()
		score.car = car
		scores_root.add_child(score)
		score.score_changed.connect(_on_score_changed.bind(slot))
		scores.append(score)

		var popups := PopupsScript.new()
		popups.car = car
		popups.score = score
		popups.z_index = 100
		popups_root.add_child(popups)

		_lines.append(_make_line(color))


## One row of the lap board. Tinted to match the car in co-op, because a line
## that does not say at a glance whose it is may as well not be on screen; left
## alone with one player, where there is nothing to tell apart.
func _make_line(color: Color) -> Label:
	var line := Label.new()
	line.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	line.add_theme_font_size_override("font_size", 12)
	if _coop:
		line.add_theme_color_override("font_color", color)
	board.add_child(line)
	return line


## Where a player starts, staggered off the start line so the field does not
## spawn inside itself. One player keeps the line to themselves, exactly on the
## spawn point the track hands out.
func _grid_slot(slot: int) -> Transform2D:
	if not _coop:
		return spawn_point
	var offset: Vector2 = GRID_OFFSETS[slot % GRID_OFFSETS.size()]
	return Transform2D(spawn_point.get_rotation(), spawn_point * offset)


func _reset_field() -> void:
	for slot in cars.size():
		cars[slot].reset(_grid_slot(slot))


func _clear_rubber() -> void:
	for skids in _skids:
		skids.clear()


## The banked total only ever moves when a combo lands, so every change is worth
## a kick. The world-space meter carries the pending number; this is the safe one.
func _on_score_changed(total: int, slot: int) -> void:
	# In co-op the score lives on the player's own board line, which is the only
	# place it can be told apart from the other three.
	_refresh_board()
	if _coop:
		return

	score_readout.text = ScoreScript.grouped(total)
	var tween := create_tween()
	tween.tween_property(score_readout, "scale", Vector2.ONE * 1.3, 0.08).set_ease(Tween.EASE_OUT)
	var settle := tween.tween_property(score_readout, "scale", Vector2.ONE, 0.32)
	settle.set_trans(Tween.TRANS_ELASTIC).set_ease(Tween.EASE_OUT)


## A wall tap ends that player's lap. The car takes itself off the board the
## moment it hits, so all of this is about what is left behind: the wreckage, the
## progress that just went with it, and putting the player back on the line once
## the blast has played out.
##
## The combo is not dealt with here; that player's score watches the same signal
## and drops it on its own. The lap system does not watch it at all, since a
## shared signal cannot say which of four cars sent it, so the pending
## checkpoints are cleared from here.
func _on_car_crashed(slot: int) -> void:
	var car := cars[slot]
	_explode(slot)
	lap_system.reset_progress(slot)
	_refresh_board()

	# A crash during the victory second stays a crash: the race is already over,
	# so the wreck is left where it lies rather than being put back on a line
	# nobody is racing from. The wipe is moments away and will clear it.
	if _finishing:
		return

	await get_tree().create_timer(RESPAWN_DELAY).timeout

	# Anything that put the field back while the wreck was burning has already
	# revived this car: the respawn button, a regenerate, or the wipe between
	# tracks. A second reset here would snatch a car that is already driving off
	# the line, so the wait only counts if the car is still dead when it ends.
	if not car.is_dead or _finishing:
		return
	car.reset(_grid_slot(slot))


## Throws one car's worth of wreckage where it died, in that player's paint and
## along the heading it was carrying. Lives on its own layer above the cars, so
## the blast covers the wreck rather than the wreck showing through it, and frees
## itself once it has burnt out.
func _explode(slot: int) -> void:
	var car := cars[slot]
	var blast := ExplosionScript.new()
	blast.color = _colors[slot]
	blast.momentum = car.death_velocity
	effects_root.add_child(blast)
	blast.global_position = car.global_position


## Somebody took the race. The whole field coasts out its last corner for a beat
## with the controls dead, then the wipe takes over. Freezing waits until the
## wipe actually starts, so the cars keep rolling through the celebration rather
## than stopping on a dime.
func _on_race_won(_player: int) -> void:
	_finishing = true
	for car in cars:
		car.input_locked = true

	await get_tree().create_timer(FINISH_RIDE_TIME).timeout

	for car in cars:
		car.set_physics_process(false)
	transition.play()


## The new track is fully revealed. Hand control back and re-arm for the next win.
func _on_transition_finished() -> void:
	for car in cars:
		car.set_physics_process(true)
		car.input_locked = false
	_finishing = false


## Runs on the wipe's black midpoint, off the transition's covered signal. Two
## things ride on that timing. The obvious one is that the new track is never
## seen popping in. The other is that covered fires from a tween, on an idle
## frame, so building the track here lands clear of the physics flush the finish
## trigger fired from, which is not allowed to add the new barrier bodies.
##
## The lap system rebuilds its own checkpoints off track.rebuilt, so this only
## has to deal with the parts arena owns: the cars and their spawn point.
func _swap_track() -> void:
	track.generate()
	spawn_point = track.get_spawn()
	_reset_field()


## Finishing the track banks whatever combo that player had pending. Crossing the
## line on any earlier lap does not: the chain stays open over the start line, so
## a combo can be held across the whole track instead of being closed off three
## times on the way through it. That is the point of moving it here. A chain
## carried from the first corner to the last is worth far more than three lap-long
## ones, and it is worth exactly nothing if the final lap ends in the wall.
##
## The laps that no longer bank do not strand anything. A pending combo lands
## itself as soon as the link window runs out, which is what happens within a
## second or two of any lap that was not still being drifted at the line, so this
## is only ever deciding when a live chain is closed early.
func _on_lap_finished(player: int, lap: int, laps: int) -> void:
	if lap < laps:
		return
	scores[player].cash_in()


## Takes optional args it ignores, so the same handler can sit on the bare
## rebuilt signal and on checkpoint_passed / lap_completed, which carry three each.
func _on_lap_progress(_a = null, _b = null, _c = null) -> void:
	_refresh_board()


func _refresh_board() -> void:
	for slot in _lines.size():
		var text := "LAP %d/%d   CP %d/%d" % [
			mini(lap_system.lap_of(slot) + 1, lap_system.laps_to_win),
			lap_system.laps_to_win,
			lap_system.next_checkpoint_of(slot),
			lap_system.checkpoint_count(),
		]
		if _coop:
			text = "P%d   %s   %s" % [slot + 1, text, ScoreScript.grouped(scores[slot].score)]
		_lines[slot].text = text
