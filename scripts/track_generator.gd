extends RefCounted

## Produces closed loops of grid cells for Track to turn into a circuit.
##
## A track is a cycle in the grid graph: an ordered list of cells where each is
## orthogonally adjacent to the next and the last wraps back to the first. Track
## derives everything else from that (tile art, rotation, barriers, spawn), so
## this file only ever reasons about shape.
##
## Two properties of grid graphs shape the whole approach. They are bipartite,
## so every cycle has an even length, and the two colour classes cap how long a
## cycle can get: on a 5x3 grid the classes hold 8 and 7 cells, so 14 is the
## ceiling and a 15-cell loop does not exist at all.
##
## The search is a randomised depth-first walk for a cycle of an exact length.
## At this grid size that is effectively instant, and asking for an exact length
## rather than "as long as possible" is what gives layout variety: the longest
## loops are also the rarest, so always taking them would return the same two
## tracks forever.

const DIRECTIONS := [Vector2i.RIGHT, Vector2i.DOWN, Vector2i.LEFT, Vector2i.UP]


## Returns an ordered closed loop of cells, wound clockwise, or an empty array if
## nothing fits.
##
## target_length of 0 tries every viable length in random order. Pass a specific
## even number to ask for a track of that size, which is the hook for making
## later stages longer.
static func generate(
	cols: int,
	rows: int,
	target_length: int,
	min_length: int,
	max_curve_run: int,
	rng: RandomNumberGenerator
) -> Array:
	var lengths := _viable_lengths(cols, rows, min_length)
	if target_length > 0:
		# Keep the requested length first, then fall back through the rest so a
		# request that cannot be satisfied still yields a track.
		lengths.erase(target_length)
		lengths.insert(0, target_length)
	else:
		_shuffle(lengths, rng)

	for length in lengths:
		var loop := _find_cycle(cols, rows, length, max_curve_run, rng)
		if not loop.is_empty():
			return orient_clockwise(loop)
	return []


## Turns a loop round so it is driven clockwise on screen, in place.
##
## The search walks whichever way it stumbles on first, so half the tracks it
## returns are driven anticlockwise. A loop driven backwards is the same shape,
## so reversing the order is the whole fix, and it means every race runs the same
## way round however the layout came out.
##
## Reversal moves cell 0 to the end, so an index into the loop taken before this
## call points somewhere else after it. Orient first, then pick the start line.
static func orient_clockwise(loop: Array) -> Array:
	if _signed_area(loop) < 0:
		loop.reverse()
	return loop


## Twice the loop's signed area, by the shoelace formula. Grid y runs down the
## screen rather than up it, which flips the usual sign convention: here a
## positive area is a loop that reads clockwise to the player.
static func _signed_area(loop: Array) -> int:
	var total := 0
	for i in loop.size():
		var a: Vector2i = loop[i]
		var b: Vector2i = loop[(i + 1) % loop.size()]
		total += a.x * b.y - b.x * a.y
	return total


## Index of a cell in the loop that sits on a straight, since the start line art
## has openings on opposite edges. Returns -1 if the loop is all corners.
static func pick_start_line(loop: Array, rng: RandomNumberGenerator) -> int:
	var straights: Array = []
	for i in loop.size():
		if not _is_curve(loop, i):
			straights.append(i)
	if straights.is_empty():
		return -1
	return straights[rng.randi_range(0, straights.size() - 1)]


## Every even length a cycle could plausibly have, longest first. The ceiling is
## twice the smaller bipartite class, which for a w*h grid is the cell count
## rounded down to even.
static func _viable_lengths(cols: int, rows: int, min_length: int) -> Array:
	var ceiling := cols * rows
	if ceiling % 2 == 1:
		ceiling -= 1
	var floor_length := maxi(4, min_length)
	if floor_length % 2 == 1:
		floor_length += 1

	var lengths: Array = []
	var length := ceiling
	while length >= floor_length:
		lengths.append(length)
		length -= 2
	return lengths


static func _find_cycle(
	cols: int, rows: int, length: int, max_curve_run: int, rng: RandomNumberGenerator
) -> Array:
	var starts := _all_cells(cols, rows)
	_shuffle(starts, rng)
	for start in starts:
		var path: Array = [start]
		var visited := {start: true}
		if _extend(path, visited, cols, rows, length, max_curve_run, rng):
			return path
	return []


static func _extend(
	path: Array,
	visited: Dictionary,
	cols: int,
	rows: int,
	length: int,
	max_curve_run: int,
	rng: RandomNumberGenerator
) -> bool:
	if path.size() == length:
		if not _adjacent(path[-1], path[0]):
			return false
		# Only once the loop is closed can the joins at the seam be judged, so
		# the run limit gets its final check on the whole cycle.
		return _max_curve_run(path) <= max_curve_run
	if path.size() > length:
		return false

	var steps := DIRECTIONS.duplicate()
	_shuffle(steps, rng)
	for step in steps:
		var next: Vector2i = path[-1] + step
		if next.x < 0 or next.y < 0 or next.x >= cols or next.y >= rows:
			continue
		if visited.has(next):
			continue

		path.append(next)
		visited[next] = true
		# Prune long corner chains as they form rather than discovering them at
		# the end. Cuts most of the search tree on tightly constrained runs.
		if _tail_curve_run(path) <= max_curve_run:
			if _extend(path, visited, cols, rows, length, max_curve_run, rng):
				return true
		path.pop_back()
		visited.erase(next)
	return false


## Is the cell at this index a corner? True when the direction in differs from
## the direction out. Wraps, so it is valid on a closed loop.
static func _is_curve(loop: Array, index: int) -> bool:
	var count := loop.size()
	var cell: Vector2i = loop[index]
	var incoming: Vector2i = cell - loop[posmod(index - 1, count)]
	var outgoing: Vector2i = loop[posmod(index + 1, count)] - cell
	return incoming != outgoing


## Longest chain of consecutive corners anywhere in a closed loop. Walks twice
## round so a chain straddling the seam is counted whole.
static func _max_curve_run(loop: Array) -> int:
	var count := loop.size()
	var all_curves := true
	for i in count:
		if not _is_curve(loop, i):
			all_curves = false
			break
	if all_curves:
		return count

	var best := 0
	var run := 0
	for k in count * 2:
		if _is_curve(loop, k % count):
			run += 1
			best = maxi(best, run)
		else:
			run = 0
	return best


## Corner chain ending at the second-to-last cell of an open path. The last cell
## has no exit direction yet, so its kind is still unknown.
static func _tail_curve_run(path: Array) -> int:
	var run := 0
	var i := path.size() - 2
	while i >= 1:
		var incoming: Vector2i = path[i] - path[i - 1]
		var outgoing: Vector2i = path[i + 1] - path[i]
		if incoming == outgoing:
			break
		run += 1
		i -= 1
	return run


static func _adjacent(a: Vector2i, b: Vector2i) -> bool:
	return absi(a.x - b.x) + absi(a.y - b.y) == 1


static func _all_cells(cols: int, rows: int) -> Array:
	var cells: Array = []
	for y in rows:
		for x in cols:
			cells.append(Vector2i(x, y))
	return cells


## Fisher-Yates against the supplied generator. Array.shuffle() uses the global
## RNG, which would ignore the seed and make runs unreproducible.
static func _shuffle(array: Array, rng: RandomNumberGenerator) -> void:
	for i in range(array.size() - 1, 0, -1):
		var j := rng.randi_range(0, i)
		var swap = array[i]
		array[i] = array[j]
		array[j] = swap
