extends Node2D

## Temporary test harness: fixed camera, a generated track, a speed readout and
## the banked drift score. Press respawn to put the car back on the start line.

const CarScript := preload("res://scripts/car.gd")
const ScoreScript := preload("res://scripts/drift_score.gd")
const LapSystemScript := preload("res://scripts/lap_system.gd")

@onready var car: CarScript = $Car
@onready var track := $Track
@onready var skid_marks := $SkidMarks
@onready var drift_score: ScoreScript = $DriftScore
@onready var lap_system: LapSystemScript = $LapSystem
@onready var transition := $ScreenTransition
@onready var readout: Label = $HUD/Readout
@onready var score_readout: Label = $HUD/Score
@onready var lap_readout: Label = $HUD/LapReadout

## How long the car coasts, uncontrolled, between crossing the finish and the
## wipe starting. Long enough to watch the run land; short enough not to drag.
const FINISH_RIDE_TIME := 1.0

var spawn_point: Transform2D
## True from the finish crossing until the new track is fully revealed. Covers
## both the coasting second and the wipe, and is what locks out player input and
## keeps a car that dies in that window dead.
var _finishing := false


func _ready() -> void:
	# Track builds itself in its own _ready, which runs before this one.
	spawn_point = track.get_spawn()
	car.reset(spawn_point)
	car.crashed.connect(_on_car_crashed)
	# Every rebuild, not just the one below, so this keeps holding once the track
	# starts regenerating on its own every few laps.
	track.rebuilt.connect(skid_marks.clear)

	# Controls scale out of their top-left corner unless told otherwise, which
	# would make the punch below throw the number sideways instead of swelling it
	# in place.
	score_readout.pivot_offset = score_readout.size * 0.5
	drift_score.score_changed.connect(_on_score_changed)

	lap_system.race_won.connect(_on_race_won)
	lap_system.checkpoint_passed.connect(_on_lap_progress)
	lap_system.lap_completed.connect(_on_lap_progress)
	lap_system.lap_completed.connect(_on_lap_finished)
	track.rebuilt.connect(_on_lap_progress)
	# The swap happens while the wipe has the screen fully black, never in view.
	transition.covered.connect(_swap_track)
	transition.finished.connect(_on_transition_finished)
	_on_lap_progress()


func _process(_delta: float) -> void:
	var state := "DRIFT" if car.is_drifting else "GRIP"
	readout.text = "%3d km/h  %s" % [roundi(absf(car.speed) * 1.35), state]


func _unhandled_input(event: InputEvent) -> void:
	# From the finish crossing through the coasting second and the wipe, the run is
	# out of the player's hands; swallow respawn and regenerate until it is back.
	if _finishing:
		return
	if event.is_action_pressed("respawn"):
		car.reset(spawn_point)
		lap_system.reset_progress()
	elif event.is_action_pressed("regenerate"):
		track.generate()
		spawn_point = track.get_spawn()
		car.reset(spawn_point)


## The banked total only ever moves when a combo lands, so every change is worth
## a kick. The world-space meter carries the pending number; this is the safe one.
func _on_score_changed(total: int) -> void:
	score_readout.text = ScoreScript.grouped(total)
	var tween := create_tween()
	tween.tween_property(score_readout, "scale", Vector2.ONE * 1.3, 0.08).set_ease(Tween.EASE_OUT)
	var settle := tween.tween_property(score_readout, "scale", Vector2.ONE, 0.32)
	settle.set_trans(Tween.TRANS_ELASTIC).set_ease(Tween.EASE_OUT)


func _on_car_crashed() -> void:
	# A crash during the victory second stays a crash: the run is already over, so
	# leave the car where it died rather than snapping it back to the line. Freeze
	# it on the spot too, or it would sit against the wall re-crashing every frame.
	# The wipe is moments away and will clear it.
	if _finishing:
		car.set_physics_process(false)
		return
	# Placeholder for the real instant-death handling. The combo is not dealt with
	# here: the score watches the same signal and drops it on its own, and the lap
	# system watches it too to clear whatever checkpoints were pending.
	car.reset(spawn_point)


## The race is over. The car coasts out the finish for a beat with the controls
## dead, then the wipe takes over. Freezing waits until the wipe actually starts,
## so the car keeps rolling through the celebration rather than stopping on a dime.
func _on_race_won() -> void:
	_finishing = true
	car.input_locked = true

	await get_tree().create_timer(FINISH_RIDE_TIME).timeout

	car.set_physics_process(false)
	transition.play()


## The new track is fully revealed. Hand control back and re-arm for the next win.
func _on_transition_finished() -> void:
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
## has to deal with the parts arena owns: the car and its spawn point.
func _swap_track() -> void:
	track.generate()
	spawn_point = track.get_spawn()
	car.reset(spawn_point)


## Crossing the finish line banks whatever combo is pending, so a lap's drifts
## are cashed into the score at the line rather than left on the link-window clock
## or carried into the next track. Fires on every lap, the final one included.
func _on_lap_finished(_lap: int, _laps: int) -> void:
	drift_score.cash_in()


## Takes optional args it ignores, so the same handler can sit on the bare
## rebuilt signal and on checkpoint_passed / lap_completed, which carry two each.
func _on_lap_progress(_a = null, _b = null) -> void:
	lap_readout.text = "LAP %d/%d   CP %d/%d" % [
		mini(lap_system.lap + 1, lap_system.laps_to_win),
		lap_system.laps_to_win,
		lap_system.next_checkpoint,
		lap_system.checkpoint_count(),
	]
