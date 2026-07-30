extends Node

## Turns the generated track into a race, entirely behind the scenes: no visuals
## of its own, just triggers and a lap count that the HUD reads.
##
## Checkpoints are areas dropped on a random subset of the track's cells, kept in
## the order the car actually drives them. Each fills its whole tile, so there is
## no line through the cell that misses it. The finish line only banks a lap once
## every checkpoint has been touched since the last crossing, which is what stops
## a lap being claimed by parking on the line or cutting the infield to skip the
## loop. Reaching laps_to_win regenerates the track.
##
## A crash or a manual respawn sends the car back to the start line, so either
## one clears whatever checkpoint progress was pending for the lap in flight.
## Laps already banked are untouched, the same way a crash costs the drift combo
## in flight but not the score already banked.

signal checkpoint_passed(index: int, total: int)
signal lap_completed(lap: int, laps_to_win: int)
signal race_won

const TrackScript := preload("res://scripts/track.gd")
const CarScript := preload("res://scripts/car.gd")
const FinishLineScene := preload("res://scenes/finish_line.tscn")

@export var track_path: NodePath = ^"../Track"
@export var car_path: NodePath = ^"../Car"

@export_group("Checkpoints")
## Share of the track's non-finish cells turned into checkpoints, redrawn at
## random on every generation.
@export_range(0.1, 1.0) var checkpoint_density := 0.45
## Floor on the count above, so a short track never generates so few that the
## finish line is effectively the whole race.
@export var min_checkpoints := 3

@export_group("Laps")
@export var laps_to_win := 3

var lap := 0
var next_checkpoint := 0

var _track: TrackScript
var _car: CarScript
var _rng := RandomNumberGenerator.new()
var _finish_area: Area2D
var _checkpoints: Array[Area2D] = []


func _ready() -> void:
	_track = get_node_or_null(track_path) as TrackScript
	_car = get_node_or_null(car_path) as CarScript
	if _track == null or _car == null:
		push_error("LapSystem: track_path or car_path is wrong, laps will not be tracked.")
		return

	_rng.randomize()
	_car.crashed.connect(reset_progress)
	_track.rebuilt.connect(_on_track_rebuilt)
	# Track has already built itself by the time this node's _ready runs, so the
	# first course is laid out directly rather than waiting on a signal that has
	# already fired. Later rebuilds come through _on_track_rebuilt.
	_rebuild_course()


func checkpoint_count() -> int:
	return _checkpoints.size()


## Clears whatever checkpoints are pending for the lap in progress, without
## touching laps already banked. Safe to call any time, including mid-course.
func reset_progress() -> void:
	next_checkpoint = 0


## A rebuild that lands mid-frame arrives while the physics server is flushing its
## queries, since the finish trigger that regenerated the track is one of those
## queries. Adding areas to a space is forbidden there, so the whole rebuild is
## pushed to the idle frame after.
func _on_track_rebuilt() -> void:
	_rebuild_course.call_deferred()


func _rebuild_course() -> void:
	_clear_course()
	lap = 0
	next_checkpoint = 0

	var cells := _pick_checkpoint_cells()
	for i in cells.size():
		_checkpoints.append(_make_trigger(cells[i], _on_checkpoint_entered.bind(i)))

	_finish_area = _make_finish()


func _clear_course() -> void:
	for area in _checkpoints:
		area.queue_free()
	_checkpoints.clear()
	if _finish_area != null:
		_finish_area.queue_free()
		_finish_area = null


## Every cell but the finish, in the order the car actually drives them starting
## just past the start line. Picking a random subset of positions within that
## list rather than shuffling the cells themselves is what keeps the chosen
## checkpoints in track order for free.
func _pick_checkpoint_cells() -> Array[Vector2i]:
	var path: Array = _track.path
	var count := path.size()
	var order: Array[int] = []
	for step in range(1, count):
		order.append(posmod(_track.finish_index + step, count))

	var wanted := clampi(
		roundi(order.size() * checkpoint_density), mini(min_checkpoints, order.size()), order.size()
	)
	var positions: Array = range(order.size())
	_shuffle(positions)
	positions = positions.slice(0, wanted)
	positions.sort()

	var cells: Array[Vector2i] = []
	for p in positions:
		cells.append(path[order[p]])
	return cells


## The trigger fills the whole tile, so there is no line through the cell that
## misses it: cross the tile and the car body is inside the area.
func _make_trigger(cell: Vector2i, on_entered: Callable) -> Area2D:
	var area := Area2D.new()
	area.position = _track.cell_to_world(cell)

	var square := RectangleShape2D.new()
	square.size = Vector2.ONE * _track.tile_size
	var shape := CollisionShape2D.new()
	shape.shape = square
	area.add_child(shape)

	area.body_entered.connect(on_entered)
	add_child(area)
	return area


## The finish, unlike the checkpoints, is a concrete scene: its collision is the
## checkered strip rather than the whole tile, so a lap banks as the car crosses
## the actual line. get_spawn already gives the finish cell's position and travel
## rotation, which is exactly the transform the strip has to sit at.
func _make_finish() -> Area2D:
	var finish: Area2D = FinishLineScene.instantiate()
	var placement := _track.get_spawn()
	finish.position = placement.origin
	finish.rotation = placement.get_rotation()
	finish.body_entered.connect(_on_finish_entered)
	add_child(finish)
	return finish


## Ignores anything out of sequence rather than erroring on it, so driving past a
## later checkpoint before an earlier one is simply a non-event: the car has to
## come back round for the one that is actually due.
func _on_checkpoint_entered(body: Node2D, index: int) -> void:
	if body != _car or index != next_checkpoint:
		return
	next_checkpoint += 1
	checkpoint_passed.emit(index, _checkpoints.size())


func _on_finish_entered(body: Node2D) -> void:
	if body != _car or next_checkpoint < _checkpoints.size():
		return
	next_checkpoint = 0

	lap += 1
	lap_completed.emit(lap, laps_to_win)
	if lap >= laps_to_win:
		race_won.emit()


func _shuffle(array: Array) -> void:
	for i in range(array.size() - 1, 0, -1):
		var j := _rng.randi_range(0, i)
		var swap = array[i]
		array[i] = array[j]
		array[j] = swap
