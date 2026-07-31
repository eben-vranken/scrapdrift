extends Node2D

## Tyre scars the car burns into the asphalt while it is sideways.
##
## Each rear wheel lays its own trail. A trail is a Line2D that grows point by
## point for as long as the slide lasts and is closed off the moment it ends, so
## one slide reads as one continuous scar rather than a dotted crumb trail.
##
## The marks do not fade with age. A lap's worth of them is a record of how that
## lap was driven, and the only things that take one away are the budget filling
## up and the surface they are painted on going away, which is why this listens
## to the track rather than a timer. Either way the mark fades out on its way
## out, so rubber never blinks off the asphalt mid-corner.
##
## Draw order is tree order: this node sits between the track and the car in the
## scene, so marks land on top of the asphalt and under the vehicle.

const CarScript := preload("res://scripts/car.gd")

## Hard ceiling on the points in one trail. A single unbroken donut would
## otherwise grow one Line2D without limit; past this the trail is closed and a
## fresh one continues from the same point, which also makes max_marks a real
## memory bound instead of a rough one.
const MAX_TRAIL_POINTS := 256

## Distance between two samples that can only mean the car was moved rather than
## driven. Respawning mid-slide would otherwise draw a scar straight across the
## infield.
const TELEPORT_GAP := 40.0

## The car laying the rubber. Assigned before this node enters the tree: the
## arena spawns one of these per player, so there is no fixed path to find it at.
var car: CarScript

@export_group("Shape")
## The rear axle in car-local pixels: x runs toward the nose, y across the car,
## so these sit behind the centre and one either side. Any number of wheels
## works; two is what the sprite has.
@export var wheel_offsets: Array[Vector2] = [Vector2(-5.0, -4.0), Vector2(-5.0, 4.0)]
@export var mark_width := 2.0
## How far the car must travel before another point is laid. Small enough that
## corners stay smooth, large enough that sitting still does not pile up points.
@export var point_spacing := 3.0

@export_group("Look")
## Rubber over asphalt. Alpha carries most of the read, since a solid black
## stripe fights the car for attention on a track where contact kills.
@export var mark_color := Color(0.055, 0.043, 0.055, 0.55)
## Slide needed before rubber goes down at all. The nose springs out from
## straight, so this is also what stops every flick of the drift button from
## stamping a mark.
@export_range(0.0, 1.0) var min_slide := 0.25
## Shades of mark between the faintest and the fullest. Line2D colours a whole
## line at once, so the trail is split at each step boundary instead, seamed on
## the shared point. 1 turns the whole thing off and lays one flat shade.
@export_range(1, 6) var intensity_steps := 3
## Width and alpha at the faintest step, as a share of the full mark. This is
## what makes a full-lock slide read differently from a trimmed one.
@export_range(0.1, 1.0) var faint_share := 0.45

## Seconds a dropped mark takes to go from full to gone. Long enough to read as
## rubber wearing off rather than a node disappearing, short enough that a wipe
## still feels like a wipe. 0 removes marks on the spot.
@export_range(0.0, 5.0) var fade_time := 0.75

@export_group("Budget")
## Oldest trails are dropped past this. Two wheels means a slide costs at least
## two, so this is roughly half the number of slides kept.
@export var max_marks := 256

var _car: CarScript
## Every mark still counted against the budget, oldest first. A dropped trail
## leaves this the moment it is dropped and spends its fade as a plain child, so
## fading rubber never holds a slot a live mark could use.
var _trails: Array[Line2D] = []
## Per wheel: the trail currently being extended, the step it was opened at, and
## where its last point landed.
var _active: Array[Line2D] = []
var _active_step: Array[int] = []
var _last_point: Array[Vector2] = []


func _ready() -> void:
	_car = car
	if _car == null:
		push_error("SkidMarks: no car was assigned, no marks will be laid.")
		set_physics_process(false)
		return

	_active.resize(wheel_offsets.size())
	_active_step.resize(wheel_offsets.size())
	_last_point.resize(wheel_offsets.size())


## Sampled on the physics tick because that is the only rate the car's own
## position changes at. Anything finer would just lay duplicate points.
func _physics_process(_delta: float) -> void:
	var slide := _car.slide_ratio()
	var laying := _car.is_drifting and slide >= min_slide
	var step := _step_for(slide)

	for wheel in wheel_offsets.size():
		if not laying:
			_active[wheel] = null  # the slide is over; the next one starts clean
			continue
		_extend(wheel, to_local(_car.global_transform * wheel_offsets[wheel]), step)


## Adds a point to a wheel's trail, opening a new one first if the old one can no
## longer take it.
func _extend(wheel: int, point: Vector2, step: int) -> void:
	var line: Line2D = _active[wheel]
	var seam := true

	if line != null:
		var gap := point.distance_to(_last_point[wheel])
		if gap > TELEPORT_GAP:
			line = null
			seam = false  # the car did not drive this, so nothing joins it
		elif step != _active_step[wheel] or line.get_point_count() >= MAX_TRAIL_POINTS:
			line = null
		elif gap < point_spacing:
			return

	if line == null:
		var previous: Line2D = _active[wheel]
		line = _open(step)
		# Start on the old trail's last point so a change of shade shows as a
		# step in the same scar rather than a break in it.
		if seam and previous != null:
			line.add_point(_last_point[wheel])
		_active[wheel] = line
		_active_step[wheel] = step

	line.add_point(point)
	_last_point[wheel] = point


func _open(step: int) -> Line2D:
	var weight := _weight(step)
	var line := Line2D.new()
	line.width = mark_width * lerpf(faint_share, 1.0, weight)
	line.default_color = Color(
		mark_color.r, mark_color.g, mark_color.b, mark_color.a * lerpf(faint_share, 1.0, weight)
	)
	line.joint_mode = Line2D.LINE_JOINT_ROUND
	line.begin_cap_mode = Line2D.LINE_CAP_ROUND
	line.end_cap_mode = Line2D.LINE_CAP_ROUND
	line.antialiased = false  # the whole game is nearest-neighbour; no soft edges
	add_child(line)

	_trails.append(line)
	# Oldest first, but never a trail a wheel is still writing into: freeing one
	# of those would leave a wheel extending a dead node.
	while _trails.size() > max_marks and not _active.has(_trails[0]):
		_drop(_trails.pop_front())
	return line


## Which shade this much slide earns. The band runs from min_slide, where rubber
## first goes down, up to a full-lock slide.
func _step_for(slide: float) -> int:
	if intensity_steps <= 1:
		return 0
	var span := 1.0 - min_slide
	var t := 1.0 if span <= 0.0 else clampf((slide - min_slide) / span, 0.0, 1.0)
	return mini(int(t * intensity_steps), intensity_steps - 1)


func _weight(step: int) -> float:
	if intensity_steps <= 1:
		return 1.0
	return float(step) / float(intensity_steps - 1)


## Wipes every mark. Meant for a track rebuild: the asphalt these were burnt into
## no longer exists.
func clear() -> void:
	for line in _trails:
		_drop(line)
	_trails.clear()
	for wheel in _active.size():
		_active[wheel] = null


## Fades the mark off the asphalt and frees it once it is gone. The node stays in
## the tree for the fade, which is safe because callers have already taken it out
## of _trails and no wheel is writing into it.
func _drop(line: Line2D) -> void:
	if fade_time <= 0.0:
		# Detached before it is freed, the same way the track drops its old tiles,
		# so the removal is visible on the frame it happens, not the frame after.
		remove_child(line)
		line.queue_free()
		return

	var tween := create_tween()
	tween.tween_property(line, "self_modulate:a", 0.0, fade_time)
	tween.tween_callback(line.queue_free)
