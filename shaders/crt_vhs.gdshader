shader_type canvas_item;
render_mode unshaded;

// CRT and VHS post-process, applied over the whole frame including the HUD.
//
// Adapted from a community Godot 4 shader. Four things changed:
//
//   pixelate defaults off. The game already renders at its native low
//   resolution with nearest filtering, so re-quantising here fights the real
//   pixel grid and throws moire.
//
//   scanline and grille frequency became their own uniforms. Originally both
//   were driven from `resolution`, which also drove pixelation, so the three
//   could not be tuned apart. At this project's resolution that forced one
//   scanline per source pixel row, which shreds art this small.
//
//   uv is resolved once. The original recomputed it from UV partway down, which
//   silently broke overlay mode on anything but a full-screen rect.
//
//   chroma smear added. Blurring colour while keeping brightness sharp is the
//   single most recognisable tape artifact and the original had no equivalent.

// filter_linear, not filter_linear_mipmap as the original had. Nothing here
// samples at a reduced LOD, so mipmaps of the screen buffer would only cost
// generation time each frame. Linear is what softens the warped pixel edges,
// which is a large part of why this reads as glass rather than a filter.
uniform sampler2D SCREEN_TEXTURE : hint_screen_texture, filter_linear;

// True samples SCREEN_UV, for a rect drawn over the finished frame. False
// samples UV, for putting this on a single sprite or panel.
uniform bool overlay = true;

group_uniforms crt;
// Number of scanlines down the whole screen. Matching the source pixel rows
// (540 here) darkens every other row and reads as stripes on sprites this
// small; half that keeps the texture without eating the art.
uniform float scanline_count = 270.0;
uniform float scanlines_opacity : hint_range(0.0, 1.0) = 0.35;
uniform float scanlines_width : hint_range(0.0, 0.5) = 0.25;
// Aperture grille triads across the screen. Real ones are far finer than a
// game pixel, so this stays subtle on purpose.
uniform float grille_count = 320.0;
uniform float grille_opacity : hint_range(0.0, 1.0) = 0.15;
uniform float brightness = 1.25;

group_uniforms crt.geometry;
uniform float warp_amount : hint_range(0.0, 5.0) = 0.6;
uniform bool clip_warp = false;
uniform float vignette_intensity = 0.35;
uniform float vignette_opacity : hint_range(0.0, 1.0) = 0.45;

group_uniforms vhs;
uniform bool roll = true;
uniform float roll_speed = 6.0;
uniform float roll_size : hint_range(0.0, 100.0) = 12.0;
uniform float roll_variation : hint_range(0.1, 5.0) = 1.8;
uniform float distort_intensity : hint_range(0.0, 0.2) = 0.03;
uniform float noise_opacity : hint_range(0.0, 1.0) = 0.25;
uniform float noise_speed = 5.0;
uniform float static_noise_intensity : hint_range(0.0, 1.0) = 0.04;
uniform float aberration : hint_range(-1.0, 1.0) = 0.02;
// Tape records colour at a fraction of the luma bandwidth, so hues bleed
// sideways off an edge while detail stays sharp.
uniform float chroma_smear : hint_range(0.0, 1.0) = 0.35;

group_uniforms vhs.colour;
uniform bool discolor = true;
uniform float saturation_loss : hint_range(0.0, 1.0) = 0.25;
uniform float contrast_boost : hint_range(0.5, 2.0) = 1.1;

group_uniforms sampling;
// Only used for pixelation and for quantising the noise. Kept in sync with the
// viewport by crt_overlay.gd so it cannot silently drift.
uniform vec2 resolution = vec2(960.0, 540.0);
uniform bool pixelate = false;


vec2 random(vec2 uv) {
	uv = vec2(dot(uv, vec2(127.1, 311.7)), dot(uv, vec2(269.5, 183.3)));
	return -1.0 + 2.0 * fract(sin(uv) * 43758.5453123);
}

float noise(vec2 uv) {
	vec2 uv_index = floor(uv);
	vec2 uv_fract = fract(uv);
	vec2 blur = smoothstep(0.0, 1.0, uv_fract);

	return mix(
		mix(dot(random(uv_index + vec2(0.0, 0.0)), uv_fract - vec2(0.0, 0.0)),
			dot(random(uv_index + vec2(1.0, 0.0)), uv_fract - vec2(1.0, 0.0)), blur.x),
		mix(dot(random(uv_index + vec2(0.0, 1.0)), uv_fract - vec2(0.0, 1.0)),
			dot(random(uv_index + vec2(1.0, 1.0)), uv_fract - vec2(1.0, 1.0)), blur.x),
		blur.y
	) * 0.5 + 0.5;
}

// Barrel distortion. Pushes pixels outward with the fourth power of their
// distance from centre, which bulges the middle like glass.
vec2 warp(vec2 uv) {
	vec2 delta = uv - 0.5;
	float delta2 = dot(delta.xy, delta.xy);
	float delta4 = delta2 * delta2;
	return uv + delta * (delta4 * warp_amount);
}

// Rounded screen edge, so the warped image ends on a bezel rather than a
// stretched smear.
float border(vec2 uv) {
	float radius = min(warp_amount, 0.08);
	radius = max(min(min(abs(radius * 2.0), abs(1.0)), abs(1.0)), 1e-5);
	vec2 abs_uv = abs(uv * 2.0 - 1.0) - vec2(1.0, 1.0) + radius;
	float dist = length(max(vec2(0.0), abs_uv)) / radius;
	return clamp(1.0 - smoothstep(0.96, 1.0, dist), 0.0, 1.0);
}

float vignette(vec2 uv) {
	uv *= 1.0 - uv.xy;
	float v = uv.x * uv.y * 15.0;
	return pow(v, vignette_intensity * vignette_opacity);
}

float luma(vec3 c) {
	return dot(c, vec3(0.299, 0.587, 0.114));
}


void fragment() {
	// Resolved once and reused for sampling, grille, scanlines and vignette, so
	// overlay mode stays consistent throughout.
	vec2 uv = warp(overlay ? SCREEN_UV : UV);
	vec2 text_uv = pixelate ? ceil(uv * resolution) / resolution : uv;

	float time = roll ? TIME : 0.0;
	vec2 roll_uv = vec2(0.0);
	float roll_line = 0.0;
	if (roll || noise_opacity > 0.0) {
		roll_line = smoothstep(0.3, 0.9, sin(uv.y * roll_size - time * roll_speed));
		roll_line *= roll_line * smoothstep(0.3, 0.9,
			sin(uv.y * roll_size * roll_variation - time * roll_speed * roll_variation));
		roll_uv = vec2(roll_line * distort_intensity * (1.0 - uv.x), 0.0);
	}

	// Split the channels for chromatic aberration. The tape's vertical hold
	// wobble displaces them by slightly different amounts, hence the 0.8/1.2.
	vec2 sample_uv = text_uv + (roll ? roll_uv : vec2(0.0));
	vec4 text;
	text.r = texture(SCREEN_TEXTURE, sample_uv + roll_uv * (roll ? -0.2 : 0.0) + vec2(aberration * 0.1, 0.0)).r;
	text.g = texture(SCREEN_TEXTURE, sample_uv + roll_uv * (roll ? 0.2 : 0.0) - vec2(aberration * 0.1, 0.0)).g;
	text.b = texture(SCREEN_TEXTURE, sample_uv).b;
	text.a = 1.0;

	if (chroma_smear > 0.0) {
		float step_uv = chroma_smear * 0.004;
		vec3 blurred = text.rgb;
		blurred += texture(SCREEN_TEXTURE, sample_uv + vec2(step_uv, 0.0)).rgb;
		blurred += texture(SCREEN_TEXTURE, sample_uv + vec2(step_uv * 2.0, 0.0)).rgb;
		blurred += texture(SCREEN_TEXTURE, sample_uv - vec2(step_uv, 0.0)).rgb;
		blurred *= 0.25;
		// Blurred colour, original brightness. That is what a tape does: full
		// detail in luma, smeared chroma.
		text.rgb = clamp(blurred + (luma(text.rgb) - luma(blurred)), 0.0, 1.0);
	}

	if (grille_opacity > 0.0) {
		float phase = uv.x * grille_count * 3.14159265;
		text.r = mix(text.r, text.r * smoothstep(0.85, 0.95, abs(sin(phase))), grille_opacity);
		text.g = mix(text.g, text.g * smoothstep(0.85, 0.95, abs(sin(1.05 + phase))), grille_opacity);
		text.b = mix(text.b, text.b * smoothstep(0.85, 0.95, abs(sin(2.1 + phase))), grille_opacity);
	}

	text.rgb = clamp(text.rgb * brightness, vec3(0.0), vec3(1.0));

	float scanlines = 0.5;
	if (scanlines_opacity > 0.0) {
		scanlines = smoothstep(scanlines_width, scanlines_width + 0.5,
			abs(sin(uv.y * scanline_count * 3.14159265)));
		text.rgb = mix(text.rgb, text.rgb * vec3(scanlines), scanlines_opacity);
	}

	if (noise_opacity > 0.0) {
		float n = smoothstep(0.4, 0.5, noise(uv * vec2(2.0, 200.0) + vec2(10.0, TIME * noise_speed)));
		roll_line *= n * scanlines
			* clamp(random(ceil(uv * resolution) / resolution + vec2(TIME * 0.8, 0.0)).x + 0.8, 0.0, 1.0);
		text.rgb = clamp(mix(text.rgb, text.rgb + roll_line, noise_opacity), vec3(0.0), vec3(1.0));
	}

	if (static_noise_intensity > 0.0) {
		text.rgb += clamp(random(ceil(uv * resolution) / resolution + fract(TIME)).x, 0.0, 1.0)
			* static_noise_intensity;
	}

	text.rgb *= border(uv);
	text.rgb *= vignette(uv);

	if (clip_warp) {
		text.a = border(uv);
	}

	if (discolor) {
		text.rgb = mix(text.rgb, vec3(luma(text.rgb)), saturation_loss);
		float midpoint = pow(0.5, 2.2);
		text.rgb = (text.rgb - vec3(midpoint)) * contrast_boost + midpoint;
	}

	COLOR = text;
}
