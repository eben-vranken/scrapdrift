shader_type canvas_item;

// Palette swap for the car body, so four players can share one sprite.
//
// The car is drawn in a single hue over a black outline, with a white
// windscreen and red tail lights. Only the two body shades are replaced here.
// Tinting the whole sprite with modulate would drag the outline and the lights
// with it, and on a track where one wall tap ends the run those are exactly the
// pixels that have to stay put.
//
// Matching is on exact authored colours with a small tolerance rather than on
// hue, because the sprite is ten pixels wide and there is no room for a match
// to be approximately right. The defaults below are what player.png is drawn
// in; change the art and these change with it.
//
// Deliberately no source_color hints: 2D renders in sRGB here, so the uniforms
// are compared against raw texel values and any conversion would break the
// match. GDScript passes plain RGB triples for the same reason.

uniform vec3 body_source = vec3(0.98039, 0.41569, 0.03922);
uniform vec3 shine_source = vec3(0.97647, 0.63922, 0.10588);

uniform vec3 body_color = vec3(0.98039, 0.41569, 0.03922);
uniform vec3 shine_color = vec3(0.97647, 0.63922, 0.10588);

// How far off an authored shade a pixel can be and still count as that shade.
// The two body shades sit far apart, so this only has to absorb whatever the
// importer does to the bytes.
uniform float tolerance = 0.02;

// COLOR arrives already holding the sampled texel, so the swap is done on it in
// place rather than on a second sample multiplied back in, which would put the
// original orange through every new colour.
//
// The one thing to know: this compares against COLOR, which is the texel times
// whatever modulate the node is wearing. That is exactly right at the default
// white and it means the body swap quietly stops matching under a coloured
// modulate. Nothing tints these sprites today, and a car that fails to recolour
// is a better failure than one that recolours wrongly.
void fragment() {
	if (distance(COLOR.rgb, body_source) <= tolerance) {
		COLOR.rgb = body_color;
	} else if (distance(COLOR.rgb, shine_source) <= tolerance) {
		COLOR.rgb = shine_color;
	}
}
