extends Node2D

## The shouting. Turns what the score model reports into text thrown around the
## car, plus the live combo meter that trails behind it.
##
## The one hard rule here is that none of this may ever sit on top of the car.
## A wall tap ends the run, so the player is reading the vehicle and the barrier
## edge past it every single frame, and a word landing over either of them is not
## juice, it is a death. Three things enforce that:
##
##   The forward cone is off limits. Text only ever goes to the sides or behind,
##   because anywhere ahead is somewhere the car is about to be.
##   Placement is measured, not guessed. Each pop is built, asked how wide it
##   turned out, and only then pushed far enough out that its box clears the car
##   at full punch. A long word ends up further away than a short one.
##   Live pops repel each other. Candidate slots are scored on how far they sit
##   from the text already on screen, so a fast chain fans out instead of piling
##   into one illegible stack.
##
## Everything is world space rather than a HUD layer, so the text sits in the
## scene with the car and the CRT pass treats it like the rest of the image.
## This node needs a z_index above the car for that to read.

const PopTextScript := preload("res://scripts/pop_text.gd")
const ScoreScript := preload("res://scripts/drift_score.gd")
const CarScript := preload("res://scripts/car.gd")

## Directions a pop may be thrown, in degrees off the car's travel line. Nothing
## inside roughly a 70 degree half-cone ahead, which is the ground the car covers
## before the text has finished appearing.
const SLOTS := [-80.0, 80.0, -118.0, 118.0, -152.0, 152.0, 180.0]

## Keep-out around the car's centre, in pixels. The body is 14x10, so this leaves
## a clear ring around it rather than just missing the collision box.
const CAR_CLEARANCE := 17.0

## What the meter wears before any tier has been reached: bone, the quiet end of
## the escalation the tier colours run through.
const BASE_METER_COLOR := Color(0.92, 0.89, 0.83)

## Largest kick _punch_meter ever gives the meter, and therefore how much bigger
## than its resting size it has to be assumed to be when it is placed.
const METER_PUNCH_PAD := 1.4

@export var car_path: NodePath = ^"../Car"
@export var score_path: NodePath = ^"../DriftScore"

@export_group("Placement")
## Smallest distance from the car a pop is placed at. Wide text is pushed out
## past this automatically; short text sits at exactly this.
@export var slot_radius := 30.0
## How far a pop drifts away from the car over its life, on top of the rise.
@export var slot_push := 14.0
## How far a pop climbs the screen over its life. This is what makes text read as
## leaving rather than sitting in the road.
@export var rise := 22.0
## Inset from the edge of the view that no text is allowed past, so a pop thrown
## near a barrier does not end up half off the screen.
@export var edge_margin := 8.0

@export_group("Type")
## Optional pixel font for every pop and the meter. Left null the project default
## is used, which is legible but soft against the rest of the art.
@export var font: Font = null
## Mid-drift tier shouts. The loud ones.
@export var tier_font_size := 13
## The "+340" a finished drift is worth.
@export var points_font_size := 11
## The multiplier stamp. Big, because raising it is the thing worth chasing.
@export var chain_font_size := 17
## The payoff when a combo lands, and the number lost when one does not.
@export var bank_font_size := 19

@export_group("Meter")
## How far behind the car the live combo sits. Behind, because that is the one
## direction the car is guaranteed to be leaving.
@export var meter_trail := 26.0
@export var meter_font_size := 11
## How quickly the meter catches up with the car, per second. Below the car's own
## speed on purpose: the lag is what makes it read as being dragged along.
@export var meter_follow := 14.0
## Times per second the meter flashes once the combo is unlanded and the link
## window is running out. This is the tell that points are about to be banked.
@export var meter_warn_rate := 7.0

@export_group("Colour")
## The scrap a drift was worth. Acid green reads as pickup rather than hazard,
## which is the distinction the design document's palette rule cares about.
@export var points_color := Color(0.60, 0.96, 0.35)
## Multiplier stamps. Hazard orange: this is the number that is at risk.
@export var chain_color := Color(1.0, 0.62, 0.13)
## A landed combo. The brightest thing on the screen for a moment.
@export var bank_color := Color(1.0, 0.94, 0.62)
## A lost one.
@export var loss_color := Color(1.0, 0.22, 0.20)

var _car: CarScript
var _score: ScoreScript
## Pops currently on screen, used to keep new ones away from them. Freed nodes
## are filtered out on read rather than tracked, since a pop frees itself.
var _live: Array[Node2D] = []

var _meter: Node2D
var _meter_label: Label
var _meter_shadow: Label
## Colour of the highest tier reached this combo, so the meter escalates with the
## drift instead of staying one flat shade.
var _meter_color := BASE_METER_COLOR
## What the label is actually wearing, so the override is only pushed when the
## tier changes rather than on every frame.
var _shown_color := BASE_METER_COLOR
## Running phase of the about-to-bank flash. See _update_meter.
var _warn_phase := 0.0
## Where the meter currently sits on its ring around the car, in radians. This
## rather than a position is what lags behind the car. See _update_meter.
var _meter_angle := 0.0
var _meter_pulse: Tween


func _ready() -> void:
	_car = get_node_or_null(car_path) as CarScript
	_score = get_node_or_null(score_path) as ScoreScript
	if _car == null or _score == null:
		push_error("DriftPopups: car_path or score_path is wrong, no drift text will appear.")
		set_process(false)
		return

	_build_meter()

	_score.tier_reached.connect(_on_tier_reached)
	_score.drift_ended.connect(_on_drift_ended)
	_score.chain_raised.connect(_on_chain_raised)
	_score.bonus_scored.connect(_on_bonus_scored)
	_score.combo_banked.connect(_on_combo_banked)
	_score.combo_lost.connect(_on_combo_lost)


func _process(delta: float) -> void:
	_update_meter(delta)


# --- the shouting ------------------------------------------------------------


func _on_tier_reached(tier: String, color: Color, index: int) -> void:
	_meter_color = color
	# Later tiers are rarer and worth more, so they are allowed to be louder and
	# to hang around longer. The first tier fires on nearly every corner and is
	# kept deliberately small so it never becomes noise.
	var loudness := 1.0 + index * 0.09
	_pop(tier, color, roundi(tier_font_size * loudness), 1.0 + index * 0.08, 1.5 + index * 0.06)
	_punch_meter(1.0 + index * 0.04)


func _on_drift_ended(points: int, _multiplier: int) -> void:
	if points <= 0:
		return
	_pop("+" + _grouped(points), points_color, points_font_size, 0.85, 1.35)


func _on_chain_raised(multiplier: int) -> void:
	_pop("x%d" % multiplier, chain_color, chain_font_size, 1.15, 1.7)
	_punch_meter(1.35)


func _on_bonus_scored(label: String, points: int) -> void:
	_pop("%s +%s" % [label, _grouped(points)], points_color, points_font_size, 0.9, 1.4)


## The payoff. Bigger, slower and higher than anything else, and it fires as the
## meter is flying off, so the two read as the same event.
func _on_combo_banked(points: int, multiplier: int) -> void:
	var text := _grouped(points) if multiplier <= 1 else "%s  x%d" % [_grouped(points), multiplier]
	_pop(text, bank_color, bank_font_size, 1.5, 1.65)
	_release_meter(bank_color, -1.0)


func _on_combo_lost(points: int) -> void:
	if points > 0:
		_pop("LOST %s" % _grouped(points), loss_color, bank_font_size, 1.4, 1.55)
	_release_meter(loss_color, 1.0)


## Builds a pop, works out where it can go without covering the car, and starts
## it. The two-step build is why placement can be measured rather than assumed.
func _pop(text: String, color: Color, size: int, life: float, punch: float) -> void:
	var pop := PopTextScript.new()
	pop.text = text
	pop.color = color
	pop.font_size = size
	pop.font = font
	pop.life = life
	pop.punch = punch
	# Added to the tree before placement, because the text has to exist to be
	# measured, and added to the repel list only afterwards, or it would be
	# counted as an obstacle while choosing its own slot.
	add_child(pop)

	var anchor := _car.global_position
	var at := _place(anchor, pop.half_size() * punch)
	var away := (at - anchor).normalized()
	pop.position = to_local(at)
	pop.travel = away * slot_push + Vector2(0.0, _rise_for(away))
	pop.play()
	_live.append(pop)


## Which way a pop drifts vertically over its life.
##
## Climbing the screen is what a Tony Hawk pop does and it is what reads best,
## but only for text that started level with the car or above it. Rising out of a
## slot below the car would carry the words straight back across the vehicle,
## which is the one thing none of this is allowed to do, so text down there sinks
## away instead.
##
## Paired with the outward push, that makes the gap to the car strictly grow for
## the whole life of every pop, from any slot.
func _rise_for(away: Vector2) -> float:
	return -rise if away.y <= 0.0 else rise


## Picks where to throw text. Every slot is a candidate; the one that ends up
## furthest from the text already on screen wins, so a chain fans out around the
## car instead of stacking in one place.
##
## Each slot is pulled back inside the view before it is judged, and any slot
## that ends up touching the car after that is thrown away. Near the edge of the
## screen the clamp is what would otherwise drag a word straight onto the
## vehicle, so it has to be applied before the check and not after.
##
## If no slot survives, the text is put behind the car and allowed to overhang
## the view. Half a word off the edge of the screen is a much cheaper mistake
## than a whole one across the car.
func _place(anchor: Vector2, padded_half: Vector2) -> Vector2:
	var forward := Vector2.from_angle(_car.travel_yaw)
	var best := Vector2.INF
	var best_score := -INF

	for slot in SLOTS:
		var degrees := float(slot)
		var direction := forward.rotated(deg_to_rad(degrees))
		var out := direction * _reach(direction, padded_half, slot_radius)
		var at := _clamp_to_view(anchor + out, padded_half)
		if not _clears_car(anchor, at, padded_half):
			continue
		# A tiny nudge toward the earlier slots, which sit beside the car rather
		# than flat behind it. Only breaks ties; spread still decides.
		var spread := _nearest_live(at) - 0.01 * absf(degrees)
		if spread > best_score:
			best_score = spread
			best = at

	if best == Vector2.INF:
		return anchor - forward * _reach(-forward, padded_half, slot_radius)
	return best


## Whether a text box at a spot leaves the keep-out ring around the car alone.
## Rect2 has no distance query, so this clamps the car's centre into the box to
## get the closest point on it and measures from there.
func _clears_car(anchor: Vector2, at: Vector2, padded_half: Vector2) -> bool:
	var closest := anchor.clamp(at - padded_half, at + padded_half)
	return closest.distance_to(anchor) >= CAR_CLEARANCE


## How far along a direction text has to sit for its box to clear the car.
##
## The second term is the box's support distance in that direction: how far its
## own edge reaches. Adding it to the keep-out means a wide word placed sideways
## is pushed out much further than the same word placed above, which is exactly
## the behaviour wanted and is why none of this is a fixed radius. A five figure
## combo is nearly as wide as the car is long, so the difference is the whole
## number sitting on the vehicle or clear of it.
func _reach(direction: Vector2, padded_half: Vector2, minimum: float) -> float:
	var support := absf(direction.x) * padded_half.x + absf(direction.y) * padded_half.y
	return maxf(minimum, CAR_CLEARANCE + support)


## Distance from a candidate spot to the nearest pop already on screen. Dead pops
## are swept here, which is the only place the list needs tending.
func _nearest_live(at: Vector2) -> float:
	var nearest := INF
	var kept: Array[Node2D] = []
	for pop in _live:
		if not is_instance_valid(pop):
			continue
		kept.append(pop)
		nearest = minf(nearest, to_global(pop.position).distance_to(at))
	_live = kept
	return nearest if nearest < INF else 1000.0


# --- the live combo meter ----------------------------------------------------


## Two labels rather than one: a hard black copy one pixel down doubles as the
## outline and the shadow, and at this size it costs less than an outlined font
## and reads heavier.
func _build_meter() -> void:
	# Each combo starts back at the quiet end of the palette and climbs from
	# there, so the colour reads on the chain in hand rather than the last one.
	_meter_color = BASE_METER_COLOR
	_shown_color = BASE_METER_COLOR
	_warn_phase = 0.0

	_meter = Node2D.new()
	_meter.visible = false
	add_child(_meter)

	_meter_shadow = _meter_label_new(Color(0.02, 0.02, 0.03, 0.85))
	_meter_shadow.position += Vector2(1.0, 1.0)
	_meter_label = _meter_label_new(_meter_color)


func _meter_label_new(tint: Color) -> Label:
	var label := Label.new()
	label.add_theme_font_size_override("font_size", meter_font_size)
	label.add_theme_color_override("font_color", tint)
	if font != null:
		label.add_theme_font_override("font", font)
	label.light_mask = 0
	label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_meter.add_child(label)
	return label


## Trails the car at a fixed distance behind, lagging on purpose. The lag is the
## whole character of it: the number gets dragged through the corner rather than
## being welded to the bumper.
func _update_meter(delta: float) -> void:
	if not _score.combo_active:
		_meter.visible = false
		return

	var text := "%s x%d" % [_grouped(roundi(_score.pending)), _score.multiplier]
	if _meter_label.text != text:
		_meter_label.text = text
		_meter_shadow.text = text
		# Re-centred on every change, or the number would grow off to one side as
		# digits are added.
		var dims := _meter_label.get_combined_minimum_size()
		_meter_label.size = dims
		_meter_shadow.size = dims
		_meter_label.position = -dims * 0.5
		_meter_shadow.position = -dims * 0.5 + Vector2(1.0, 1.0)

	# Padded for the punch, because the meter is placed at rest size but spends a
	# good part of a combo mid-kick, and the kick grows it toward the car.
	var half := _meter_label.size * 0.5 * METER_PUNCH_PAD
	var behind := _car.travel_yaw + PI
	if not _meter.visible:
		# A fresh combo starts settled rather than swinging in from wherever on
		# the track the last one happened to die.
		_meter.visible = true
		_meter_angle = behind
		_meter.modulate = Color.WHITE
		_meter.scale = Vector2.ONE

	# What lags is the angle, not the position. Sliding the meter straight toward
	# a new spot would drag it across the car every time the travel line swung
	# hard, which is precisely what happens in a drift and precisely when the
	# meter is on screen. Orbiting instead keeps the ring around the car intact
	# through any amount of rotation, and still trails through the corner.
	#
	# Exponential rather than a plain lerp, so it feels the same at any frame rate.
	var catch_up := 1.0 - exp(-meter_follow * delta)
	_meter_angle = lerp_angle(_meter_angle, behind, catch_up)

	# meter_trail is only the floor here: once the number is long enough that a
	# fixed trail would put it under the vehicle, the number wins.
	var direction := Vector2.from_angle(_meter_angle)
	var anchor := _car.global_position
	var target := anchor + direction * _reach(direction, half, meter_trail)
	# Clamping near the edge of the view can pull the meter back over the car. It
	# is better off hanging off the screen edge than sitting on the vehicle.
	var clamped := _clamp_to_view(target, half)
	_meter.global_position = clamped if _clears_car(anchor, clamped, half) else target

	if _shown_color != _meter_color:
		_shown_color = _meter_color
		_meter_label.add_theme_color_override("font_color", _meter_color)

	# Once the drift is over the combo is unlanded and on a clock. Flashing is the
	# warning, and it speeds up as the window closes.
	#
	# The phase is accumulated rather than read off the clock, because the rate
	# changes every frame and multiplying a wall clock by a changing rate makes
	# the blink jump about instead of tightening.
	var urgency := 1.0 - _score.link_share()
	if urgency > 0.0:
		_warn_phase += delta * TAU * meter_warn_rate * urgency
		var blink := 0.5 + 0.5 * sin(_warn_phase)
		_meter.modulate.a = lerpf(1.0, 0.4 + 0.6 * blink, urgency)
	else:
		_warn_phase = 0.0
		_meter.modulate.a = 1.0


## A short scale kick. Every time the combo grows the number should move, or the
## meter turns into a readout and stops being a reward.
func _punch_meter(strength: float) -> void:
	if not _meter.visible:
		return
	if _meter_pulse != null and _meter_pulse.is_valid():
		_meter_pulse.kill()
	_meter.scale = Vector2.ONE * strength
	_meter_pulse = create_tween()
	var step := _meter_pulse.tween_property(_meter, "scale", Vector2.ONE, 0.28)
	step.set_trans(Tween.TRANS_ELASTIC).set_ease(Tween.EASE_OUT)


## Hands the meter off to the pop that replaces it. It flares, throws itself in
## the given screen direction and fades, so banking and losing a combo both end
## with the number visibly leaving rather than blinking off.
func _release_meter(tint: Color, vertical: float) -> void:
	if not _meter.visible:
		return
	if _meter_pulse != null and _meter_pulse.is_valid():
		_meter_pulse.kill()

	# Detached from the follow logic before it flies, or _update_meter would drag
	# it back toward the car for as long as the tween ran.
	var ghost := _meter
	# The side of the car it was last sitting on, taken before _build_meter resets
	# the orbit. Sent outward as well as up or down, so the flare cannot swell
	# back over the vehicle on its way out.
	var away := Vector2.from_angle(_meter_angle) * 16.0
	_meter_label.add_theme_color_override("font_color", tint)
	_build_meter()

	var tween := create_tween()
	tween.set_parallel(true)
	var flare := tween.tween_property(ghost, "scale", Vector2.ONE * 1.6, 0.34)
	flare.set_trans(Tween.TRANS_BACK).set_ease(Tween.EASE_OUT)
	var fly := tween.tween_property(
		ghost, "position", ghost.position + away + Vector2(0.0, 26.0 * vertical), 0.34
	)
	fly.set_trans(Tween.TRANS_QUINT).set_ease(Tween.EASE_OUT)
	tween.tween_property(ghost, "modulate:a", 0.0, 0.34).set_delay(0.08)
	tween.finished.connect(ghost.queue_free)


# --- helpers -----------------------------------------------------------------


## The world rectangle the camera is actually showing, so text can be kept inside
## it. Assumes the camera is not rotated, which the fixed top-down framing in the
## design document guarantees.
func _view_rect() -> Rect2:
	var size := get_viewport_rect().size
	var camera := get_viewport().get_camera_2d()
	if camera == null:
		return Rect2(-size * 0.5, size)
	var span := size / camera.zoom
	return Rect2(camera.get_screen_center_position() - span * 0.5, span)


func _clamp_to_view(at: Vector2, half: Vector2) -> Vector2:
	var view := _view_rect()
	var low := view.position + half + Vector2(edge_margin, edge_margin)
	var high := view.end - half - Vector2(edge_margin, edge_margin)
	if low.x > high.x or low.y > high.y:
		return at  # the view is smaller than the text; leave it alone
	return at.clamp(low, high)


func _grouped(value: int) -> String:
	return ScoreScript.grouped(value)
