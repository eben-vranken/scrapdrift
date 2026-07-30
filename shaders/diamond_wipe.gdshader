shader_type canvas_item;
render_mode unshaded;

// Diamond-grid screen wipe, the kind a 16-bit console used between rooms.
//
// The screen is cut into a grid of square cells, each holding a diamond of the
// cover colour that grows from its centre. Rather than every diamond growing at
// once, a wavefront crosses the screen diagonally: the top-left cell fills first
// and the bottom-right last, so the cover sweeps corner to corner. Running
// progress 0 -> 1 sweeps the frame away; 1 -> 0 sweeps it back, same direction,
// so the two halves read as one bar travelling across.
//
// There is no fade anywhere in here: a pixel is either covered or it is not, so
// the edge of each diamond stays hard the whole way across rather than
// dissolving. That hard edge is the whole look, and the CRT pass on the layer
// above softens it just enough to sit with the rest of the image.

// How many cells span the width. More cells means smaller, denser diamonds.
// Aspect is corrected in fragment so the cells stay square.
uniform float cell_count = 14.0;

// 0 shows nothing of the wipe, 1 is a fully covered screen.
uniform float progress : hint_range(0.0, 1.0) = 0.0;

// How much of the diagonal is mid-wipe at any instant, as a share of its length.
// Small values give a tight, near-straight sweep line; large values spread the
// growing diamonds into a broad diagonal band. 0 makes the whole screen fill at
// once, which is the old everywhere-together behaviour.
uniform float spread : hint_range(0.0, 2.0) = 0.6;

uniform vec4 cover_color : source_color = vec4(0.0, 0.0, 0.0, 1.0);

void fragment() {
	// Square cells regardless of a wide viewport. cell_count cells span the width;
	// the height gets however many the aspect ratio asks for so a cell stays as
	// tall as it is wide. SCREEN_PIXEL_SIZE.x / .y is height / width, which is
	// exactly the count scale the vertical axis needs.
	vec2 counts = vec2(cell_count, cell_count * SCREEN_PIXEL_SIZE.x / SCREEN_PIXEL_SIZE.y);
	vec2 grid = UV * counts;

	// Manhattan distance from the cell centre draws a diamond rather than a circle.
	// It runs 0 at the centre out to 1.0 at the four corners.
	vec2 cell = fract(grid) - 0.5;
	float d = abs(cell.x) + abs(cell.y);

	// Where this cell sits along the top-left to bottom-right diagonal, 0 to 1.
	// Taken from the cell centre so every pixel of one diamond shares a value and
	// the diamond grows evenly instead of being skewed across its own width.
	vec2 cell_center = (floor(grid) + 0.5) / counts;
	float diagonal = (cell_center.x + cell_center.y) * 0.5;

	// The wavefront. progress is stretched by (1 + spread) and offset by the
	// cell's place on the diagonal, so top-left cells reach full cover before
	// progress hits 1 and bottom-right cells only get there right at the end.
	float local = clamp(progress * (1.0 + spread) - diagonal * spread, 0.0, 1.0);

	// Hard cut, no blend. Covered wherever the diamond has grown past this pixel.
	float covered = step(d, local);
	COLOR = vec4(cover_color.rgb, covered * cover_color.a);
}
