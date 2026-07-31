extends Node2D

## Builds a race track by stitching square tiles onto a grid.
##
## The only input is an ordered, closed loop of grid cells. Everything else is
## derived from it: which tile art each cell uses, how far that art is rotated,
## where the barriers sit, and where the car starts.
##
## Grid dimensions, tile size and corridor width are all parameters, and every
## piece of barrier geometry is computed from them. Moving to a different grid is
## three numbers in the inspector plus tile art at the matching size.

## Fires once the old track is gone and the new path is known, before the new
## geometry exists. Anything painted onto the old surface, skid marks included,
## is stale from here on.
signal rebuilt

enum TileKind { STRAIGHT, CURVE }

const TEXTURES := {
	"straight": preload("res://textures/tiles/straight.png"),
	"curve": preload("res://textures/tiles/curve.png"),
	"finish": preload("res://textures/tiles/finish.png"),
}

## Segments each arc of a curve tile's collision is approximated with. At a 120px
## tile, 14 holds the outer wall within a fifth of a pixel of the drawn arc.
const OUTER_ARC_STEPS := 14
const INNER_ARC_STEPS := 8

const Generator := preload("res://scripts/track_generator.gd")

@export_group("Grid")
## Must match the tile art's pixel size. Warns on build if it does not.
@export var tile_size := 120
@export var grid_cols := 7
@export var grid_rows := 4
## Width of the drivable corridor. Barrier depth is whatever is left over, split
## evenly either side, which is what keeps openings centred on every tile edge
## and lets any tile connect to any other.
##
## This is baked into the tile art as well, so changing it here alone desyncs
## collision from the visuals. The art currently runs 20..99, so 80.
@export var corridor_width := 80

@export_group("Generation")
## Off builds the plain perimeter loop instead, which is handy when tuning
## handling against a layout you already know.
@export var randomize_on_start := true
## 0 draws a fresh seed each run. Any other value reproduces the same track,
## which is what you want when chasing a bug on a specific layout.
@export var track_seed := 0
## Shortest loop worth racing. Lengths are drawn roughly evenly between this and
## the grid's maximum, so on a large grid a low floor means the occasional stubby
## track rattling around an otherwise empty frame. Raise it as the grid grows.
@export var min_loop_length := 10
## Cap on consecutive corners. Corners cost speed, so long chains are chicanes
## with no recovery room. 1 permits only isolated corners. How much variety a cap
## buys depends entirely on grid size: on 5x3 only 26 loops survive a cap of 2,
## on 6x4 it is 308, and loosening to 3 there gives 1147.
@export var max_curve_run := 2
## 0 picks a random viable length. Set it to grow the track between stages.
@export var target_loop_length := 0

var path: Array = []
var finish_index := 0

var _rng := RandomNumberGenerator.new()


func _ready() -> void:
	if randomize_on_start:
		generate()
	else:
		_build_fallback()


## Rolls a new track and builds it. Falls back to the perimeter loop rather than
## leaving the player on an empty screen if the constraints cannot be met.
func generate(seed_value := 0, length := -1) -> void:
	if seed_value != 0:
		_rng.seed = seed_value
	elif track_seed != 0:
		_rng.seed = track_seed
	else:
		_rng.randomize()

	var wanted := target_loop_length if length < 0 else length
	var loop := Generator.generate(
		grid_cols, grid_rows, wanted, min_loop_length, max_curve_run, _rng
	)
	if loop.is_empty():
		push_warning("Track: no loop satisfied the constraints, using the perimeter.")
		_build_fallback()
		return

	var start_line := Generator.pick_start_line(loop, _rng)
	if start_line < 0:
		push_warning("Track: generated loop is all corners, using the perimeter.")
		_build_fallback()
		return

	build(loop, start_line)


## The perimeter of any grid at least 2x2 is always a legal loop with nothing but
## isolated corners, which makes it a safe answer at any grid size.
func _build_fallback() -> void:
	var loop := Generator.orient_clockwise(_perimeter_loop())
	build(loop, maxi(0, Generator.pick_start_line(loop, _rng)))


func _perimeter_loop() -> Array:
	var loop: Array = []
	for x in grid_cols:
		loop.append(Vector2i(x, 0))
	for y in range(1, grid_rows):
		loop.append(Vector2i(grid_cols - 1, y))
	for x in range(grid_cols - 2, -1, -1):
		loop.append(Vector2i(x, grid_rows - 1))
	for y in range(grid_rows - 2, 0, -1):
		loop.append(Vector2i(0, y))
	return loop


func build(loop: Array, start_line_index: int) -> void:
	# Detach immediately rather than waiting on queue_free, so a rebuild never
	# leaves last track's barriers colliding for a frame.
	for child in get_children():
		remove_child(child)
		child.queue_free()

	path = loop
	finish_index = start_line_index
	rebuilt.emit()
	if not _validate(loop):
		return
	_check_fit()

	for i in loop.size():
		var cell: Vector2i = _at(i)
		# Where the car entered from, and where it leaves to. Those two
		# directions are the tile's two openings.
		var incoming: Vector2i = cell - _at(i - 1)
		var outgoing: Vector2i = _at(i + 1) - cell
		_place_tile(cell, [-incoming, outgoing], outgoing, i == start_line_index)


## Centre of a grid cell in world space. The grid is always centred on the
## origin, which is where the locked camera sits, so changing its dimensions
## keeps the track framed without touching the camera.
func cell_to_world(cell: Vector2i) -> Vector2:
	var origin := -Vector2(grid_cols, grid_rows) * tile_size * 0.5
	return origin + (Vector2(cell) + Vector2(0.5, 0.5)) * tile_size


## Where the car belongs on the grid: the centre of the start line's tile, facing
## down the track. The checkered band sits on that tile's far edge, so this is
## half a tile short of the line rather than on top of it, and the first crossing
## counts a lap the same way every later one does.
func get_spawn() -> Transform2D:
	if path.is_empty():
		return Transform2D.IDENTITY
	var cell: Vector2i = _at(finish_index)
	var outgoing: Vector2i = _at(finish_index + 1) - cell
	return Transform2D(Vector2(outgoing).angle(), cell_to_world(cell))


func _at(i: int) -> Vector2i:
	return path[posmod(i, path.size())]


func _validate(loop: Array) -> bool:
	if loop.size() < 4:
		push_error("Track: a closed loop needs at least 4 cells.")
		return false
	for i in loop.size():
		var a: Vector2i = loop[i]
		var b: Vector2i = loop[posmod(i + 1, loop.size())]
		if absi(a.x - b.x) + absi(a.y - b.y) != 1:
			push_error("Track: cells %s and %s are not adjacent." % [a, b])
			return false
		if a.x < 0 or a.y < 0 or a.x >= grid_cols or a.y >= grid_rows:
			push_error("Track: cell %s is outside the %dx%d grid." % [a, grid_cols, grid_rows])
			return false
	return true


## Catches the two mistakes that a different grid size invites: art that is no
## longer the tile size, and a track that no longer fits the locked camera.
func _check_fit() -> void:
	var art_size: int = TEXTURES["straight"].get_width()
	if art_size != tile_size:
		push_warning(
			"Track: tile_size is %d but the art is %dpx. Barriers will not line up."
			% [tile_size, art_size]
		)
	if corridor_width >= tile_size:
		push_error("Track: corridor_width must be smaller than tile_size.")
		return
	var footprint := Vector2(grid_cols, grid_rows) * tile_size
	var frame := get_viewport_rect().size
	if footprint.x > frame.x or footprint.y > frame.y:
		push_warning(
			"Track: a %dx%d grid of %dpx tiles is %s, larger than the %s frame. The camera is locked, so part of the track will be off screen."
			% [grid_cols, grid_rows, tile_size, footprint, frame]
		)


func _place_tile(cell: Vector2i, openings: Array, outgoing: Vector2i, is_finish: bool) -> void:
	var fit := _fit_tile(openings)
	if fit.is_empty():
		push_error("Track: no tile fits cell %s with openings %s." % [cell, openings])
		return

	var kind: TileKind = fit["kind"]
	if is_finish and kind != TileKind.STRAIGHT:
		push_warning("Track: start line landed on a corner, art will not line up.")

	var pos := cell_to_world(cell)
	var rot: float = fit["turns"] * PI / 2.0

	var art := "curve" if kind == TileKind.CURVE else "straight"
	var sprite_rot := rot
	if is_finish:
		art = "finish"
		# The other tiles are symmetric under a half turn, so the fit's rotation is
		# as good as any. The start line is not: its checkered band sits on one
		# edge, and that edge has to be the one the car is driving towards. Taking
		# the rotation from the direction of travel instead of the fit is what puts
		# the line ahead of the spawn rather than behind it.
		sprite_rot = Vector2(outgoing).angle()

	var sprite := Sprite2D.new()
	sprite.texture = TEXTURES[art]
	sprite.position = pos
	sprite.rotation = sprite_rot
	add_child(sprite)

	var body := StaticBody2D.new()
	body.position = pos
	body.rotation = rot
	body.add_to_group("wall")
	add_child(body)
	for piece in _barriers_for(kind):
		body.add_child(piece)


## Finds which tile art, rotated how far, has openings on exactly these two
## sides. Base orientations: straight runs left-right, curve joins left to
## bottom. A quarter turn clockwise maps (x, y) to (-y, x).
func _fit_tile(openings: Array) -> Dictionary:
	for turns in 4:
		if _same_pair(openings, [_turn(Vector2i.LEFT, turns), _turn(Vector2i.RIGHT, turns)]):
			return {"kind": TileKind.STRAIGHT, "turns": turns}
	for turns in 4:
		if _same_pair(openings, [_turn(Vector2i.LEFT, turns), _turn(Vector2i.DOWN, turns)]):
			return {"kind": TileKind.CURVE, "turns": turns}
	return {}


func _turn(dir: Vector2i, quarter_turns: int) -> Vector2i:
	var result := dir
	for i in posmod(quarter_turns, 4):
		result = Vector2i(-result.y, result.x)
	return result


func _same_pair(a: Array, b: Array) -> bool:
	return (a[0] == b[0] and a[1] == b[1]) or (a[0] == b[1] and a[1] == b[0])


## Barrier shapes in tile-local space, origin at the tile centre so they rotate
## with the sprite.
##
## Everything here is derived from tile_size and corridor_width. Naming the tile
## T, the corridor W and the leftover barrier depth D = (T - W) / 2:
##
##   a straight is two bands, T long and D deep, sitting (W + D) / 2 off centre
##   a curve is two arcs about the tile corner, at radii T/2 - W/2 and T/2 + W/2
##
## The corridor is always centred on every edge, which is what lets any tile
## connect to any other regardless of size, and it is also why the curve's arc
## centre is exactly the tile corner and its centreline radius is exactly T/2.
func _barriers_for(kind: TileKind) -> Array:
	var half := tile_size * 0.5
	var depth := (tile_size - corridor_width) * 0.5
	var band := (corridor_width + depth) * 0.5

	match kind:
		TileKind.STRAIGHT:
			return [
				_rect(Vector2(0, -band), Vector2(tile_size, depth)),
				_rect(Vector2(0, band), Vector2(tile_size, depth)),
			]
		TileKind.CURVE:
			var centre := Vector2(-half, half)

			# Inside of the bend: a quarter disc sitting on the tile corner.
			var inner := PackedVector2Array([centre])
			inner.append_array(_arc(centre, half - corridor_width * 0.5, INNER_ARC_STEPS))

			# Outside of the bend: everything beyond the outer radius, which is
			# that arc plus the three tile corners it never reaches.
			var outer := _arc(centre, half + corridor_width * 0.5, OUTER_ARC_STEPS, true)
			outer.append(Vector2(half, half))
			outer.append(Vector2(half, -half))
			outer.append(Vector2(-half, -half))

			return [_poly(inner), _poly(outer)]
	return []


## Samples the quarter turn a curve tile sweeps: from straight up out of the
## corner round to straight out along the bottom, matching the art's arc.
##
## A chord always cuts inside the circle it approximates. On the outer wall that
## would lay barrier over drawn road, so circumscribe pushes the radius out just
## far enough for the chord midpoints to land exactly on the drawn edge. The
## inner wall wants no such nudge: cutting inside there only ever hands the car
## more room at the apex, which is the direction to err when contact kills.
func _arc(centre: Vector2, radius: float, steps: int, circumscribe := false) -> PackedVector2Array:
	var effective := radius
	if circumscribe:
		effective /= cos(PI * 0.25 / float(steps))

	var points := PackedVector2Array()
	for i in steps + 1:
		var angle := lerpf(-PI * 0.5, 0.0, float(i) / float(steps))
		points.append(centre + Vector2(cos(angle), sin(angle)) * effective)
	return points


func _rect(offset: Vector2, size: Vector2) -> CollisionShape2D:
	var shape := RectangleShape2D.new()
	shape.size = size
	var node := CollisionShape2D.new()
	node.shape = shape
	node.position = offset
	return node


func _poly(points: PackedVector2Array) -> CollisionPolygon2D:
	var node := CollisionPolygon2D.new()
	node.polygon = points
	return node
