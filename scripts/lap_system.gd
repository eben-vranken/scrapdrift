extends Node

## Turns the generated track into a race, entirely behind the scenes: no visuals
## of its own, just triggers and a lap count per player that the HUD reads.
##
## Checkpoints are areas dropped on a random subset of the track's cells, kept in
## the order the car actually drives them. Each fills its whole tile, so there is
## no line through the cell that misses it. The finish line only banks a lap once
## every checkpoint has been touched since the last crossing, which is what stops
## a lap being claimed by parking on the line or cutting the infield to skip the
## loop. The first player to reach laps_to_win wins, which regenerates the track.
##
## The course itself is shared: one set of checkpoints and one finish line for
## the whole field, since they are the same corners for everybody. What is per
## player is the progress through them, which is why every signal here leads with
## a player index and why lap and checkpoint counts are arrays rather than
## numbers. Four cars driving the same tile is four separate crossings of the
## same trigger, told apart by which body came through.
##
## A crash or a manual respawn sends a car back to the line, so either one clears
## whatever checkpoint progress that player had pending for the lap in flight.
## Laps already banked are untouched, the same way a crash costs the drift combo
## in flight but not the score already banked. The arena owns crash handling and
## calls reset_progress; this node does not watch the cars itself, because it
## would have no way to tell which one of four sent the signal.

signal checkpoint_passed(player: int, index: int, total: int)
signal lap_completed(player: int, lap: int, laps_to_win: int)
signal race_won(player: int)

const TrackScript := preload("res://scripts/track.gd")
const CarScript := preload("res://scripts/car.gd")
const FinishLineScene := preload("res://scenes/finish_line.tscn")

@export var track_path: NodePath = ^"../Track"

@export_group("Checkpoints")
## Share of the track's non-finish cells turned into checkpoints, redrawn at
## random on every generation.
@export_range(0.1, 1.0) var checkpoint_density := 0.45
## Floor on the count above, so a short track never generates so few that the
## finish line is effectively the whole race.
@export var min_checkpoints := 3

@export_group("Laps")
@export var laps_to_win := 3

## Laps banked, and the checkpoint each player is due next. Both indexed by
## player, both the length of the registered field.
var laps: Array[int] = []
var next_checkpoints: Array[int] = []

## Who took the race, or -1 while it is still open. Latched so a second car
## crossing the line a moment later cannot win a race that is already over.
var winner := -1

var _track: TrackScript
var _cars: Array[CarScript] = []
var _rng := RandomNumberGenerator.new()
var _finish_area: Area2D
var _checkpoints: Array[Area2D] = []


func _ready() -> void:
	_track = get_node_or_null(track_path) as TrackScript
	if _track == null:
		push_error("LapSystem: track_path is wrong, laps will not be tracked.")
		return

	_rng.randomize()
	_track.rebuilt.connect(_on_track_rebuilt)
	# No course is laid out here. Children are ready before their parent, so the
	# arena has not spawned its field yet and there is nothing to track; set_cars
	# does the first build once it has.


## Registers the field, in grid order. The player index every signal here carries
## is a position in this array. Rebuilds the course, so it is safe to call at any
## point rather than only before the first race.
func set_cars(cars: Array) -> void:
	_cars.clear()
	for car in cars:
		var typed := car as CarScript
		if typed != null:
			_cars.append(typed)
	if _track != null:
		_rebuild_course()


func checkpoint_count() -> int:
	return _checkpoints.size()


func lap_of(player: int) -> int:
	return laps[player] if player >= 0 and player < laps.size() else 0


func next_checkpoint_of(player: int) -> int:
	return next_checkpoints[player] if player >= 0 and player < next_checkpoints.size() else 0


## Clears the checkpoints pending for one player's lap in progress, without
## touching laps already banked or anybody else's race. Safe to call any time.
func reset_progress(player: int) -> void:
	if player >= 0 and player < next_checkpoints.size():
		next_checkpoints[player] = 0


func reset_all_progress() -> void:
	for player in next_checkpoints.size():
		next_checkpoints[player] = 0


## A rebuild that lands mid-frame arrives while the physics server is flushing its
## queries, since the finish trigger that regenerated the track is one of those
## queries. Adding areas to a space is forbidden there, so the whole rebuild is
## pushed to the idle frame after.
func _on_track_rebuilt() -> void:
	_rebuild_course.call_deferred()


func _rebuild_course() -> void:
	_clear_course()
	laps.clear()
	next_checkpoints.clear()
	laps.resize(_cars.size())
	next_checkpoints.resize(_cars.size())
	winner = -1

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
	# Watches the cars layer and sits on none of its own. Nothing needs to find
	# a checkpoint, and without the mask the barriers standing inside the tile
	# would trip it on every rebuild.
	area.collision_layer = 0
	area.collision_mask = 2

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
## come back round for the one that is actually due. Bodies that are not part of
## the field, which now includes the other players' cars nudging each other
## through a corner, fall out on the lookup.
func _on_checkpoint_entered(body: Node2D, index: int) -> void:
	var player := _player_of(body)
	if player < 0 or index != next_checkpoints[player]:
		return
	next_checkpoints[player] += 1
	checkpoint_passed.emit(player, index, _checkpoints.size())


func _on_finish_entered(body: Node2D) -> void:
	var player := _player_of(body)
	if player < 0 or next_checkpoints[player] < _checkpoints.size():
		return
	next_checkpoints[player] = 0

	laps[player] += 1
	lap_completed.emit(player, laps[player], laps_to_win)
	if laps[player] >= laps_to_win and winner < 0:
		winner = player
		race_won.emit(player)


## Which player drove into a trigger, or -1 for anything that is not one of
## theirs. The triggers only watch the cars layer, so in practice nothing else
## arrives; the type is still checked first because a typed array does not
## politely fail to find something it could never hold, it errors.
func _player_of(body: Node2D) -> int:
	var car := body as CarScript
	return _cars.find(car) if car != null else -1


func _shuffle(array: Array) -> void:
	for i in range(array.size() - 1, 0, -1):
		var j := _rng.randi_range(0, i)
		var swap = array[i]
		array[i] = array[j]
		array[j] = swap
