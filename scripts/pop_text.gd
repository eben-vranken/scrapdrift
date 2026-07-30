extends Node2D

## One line of shouting text that punches onto the track, floats, and evaporates.
##
## Everything is configured by assigning the fields before the node is added to
## the tree. The animation starts itself in _ready and the node frees itself at
## the end of it, so nothing has to own one of these or tick it.
##
## The pop is four effects stacked, and each is doing a specific job:
##
##   scale  - overshoots past full size and springs back. This is the whole
##            reason the text reads as an impact rather than an appearance. Take
##            it out and everything below stops being juice and starts being a
##            label.
##   tilt   - a random lean that unwinds as it settles, so two pops in a row
##            never look like the same asset stamped twice.
##   travel - fast at first, then almost stopped. The eye catches the movement,
##            then the text sits still long enough to actually be read.
##   flash  - the first frames are blown out to white before the real colour
##            arrives. Costs nothing and is most of the "pop".
##
## Under the text sits an offset copy in a cool tone. At this resolution that
## reads as the chromatic bleed the CRT pass is already selling, and it is what
## keeps small text from going flat against a dark, busy track.
##
## The label is a child positioned at minus half its own size, so the Node2D
## origin is the middle of the text and scale and rotation pivot there for free.

## Where the offset copy sits, in pixels. One pixel, because the game is
## nearest-neighbour and anything softer than a whole pixel is a blur.
const CHROMA_OFFSET := Vector2(1.0, 1.0)

## How long the overshoot takes, and how long the spring back to full size takes.
## Both deliberately short: the text has to be legible almost immediately,
## because the car is still being driven while it plays.
const PUNCH_TIME := 0.16
const SETTLE_TIME := 0.18

## Share of the life spent fading out. The rest is punch plus hold.
const FADE_SHARE := 0.34

## How long the blown-out white lasts before the real colour arrives.
const FLASH_TIME := 0.08

## Extra size the text swells to while it fades, so it evaporates outward
## instead of just dimming.
const EVAPORATE_SCALE := 1.18

var text := ""
var color := Color.WHITE
## The offset copy underneath. Cool against the warm score palette, which is what
## makes the fringe read as bleed rather than as a drop shadow.
var chroma := Color(0.29, 0.83, 1.0, 0.45)
var font_size := 14
## Black keyline. The track is grey concrete and near-black asphalt, so without
## this the text loses its edges over half the surfaces in the game.
var outline_size := 5
## How far past full size the punch goes. 1.0 disables the overshoot.
var punch := 1.5
## Random lean, in degrees. The text starts at a multiple of this and unwinds to
## a fraction of it.
var tilt_degrees := 8.0
## Where the text ends up relative to where it spawned. Rising is what separates
## it from the car; the caller adds a sideways push to send it clear of the
## racing line as well.
var travel := Vector2(0.0, -20.0)
var life := 1.05
## Optional pixel font. Left null the project default is used, which is legible
## but soft; dropping a bitmap font in here is what finally matches the art.
var font: Font = null

var _label: Label
var _chroma_label: Label


## Building and playing are separate steps, and the caller has to ask for the
## second one. The text cannot be positioned until it has been measured, and it
## cannot be measured until it is in the tree, so the spawner needs a moment
## between the two to decide where this actually goes.
func _ready() -> void:
	_chroma_label = _build_label(chroma, 0)
	_chroma_label.position += CHROMA_OFFSET
	# Built second so it draws over the bleed copy.
	_label = _build_label(Color.WHITE, outline_size)


## Half the space the text occupies, before the punch inflates it. What the
## spawner needs in order to keep a long word off the car.
func half_size() -> Vector2:
	return _label.size * 0.5 if _label != null else Vector2.ZERO


## Both copies are the same text at the same size, so the bleed sits exactly one
## pixel off the real glyphs instead of smearing at the ends of long words.
##
## Only the top copy carries an outline. Outlining the bleed as well would put
## black between the two and turn the fringe into a shadow.
func _build_label(tint: Color, outline: int) -> Label:
	var label := Label.new()
	label.text = text
	label.add_theme_font_size_override("font_size", font_size)
	label.add_theme_color_override("font_color", tint)
	if font != null:
		label.add_theme_font_override("font", font)
	if outline > 0:
		label.add_theme_constant_override("outline_size", outline)
		label.add_theme_color_override("font_outline_color", Color(0.02, 0.02, 0.03, 1.0))
	# Track lights must never dim the score. The colours here are the read.
	label.light_mask = 0
	label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(label)

	var dims := label.get_combined_minimum_size()
	label.size = dims
	label.position = -dims * 0.5
	return label


## Runs the whole animation and frees the node at the end of it. Call once, after
## position has been set.
func play() -> void:
	var fade_time := life * FADE_SHARE
	# The hold cannot be allowed to go negative on a short-lived pop, or the fade
	# would start before the punch finished and the text would never be at full
	# size and full opacity at the same time.
	var hold_end := maxf(life - fade_time, PUNCH_TIME + SETTLE_TIME)
	var lean := deg_to_rad(randf_range(-tilt_degrees, tilt_degrees))

	# Not quite zero. A zero-scale Node2D is a degenerate transform, and one frame
	# of it is not worth the engine warnings it can draw.
	scale = Vector2.ONE * 0.01
	rotation = lean

	var start := position
	var tween := create_tween()
	tween.set_parallel(true)

	# Nothing to full size and past it.
	var punch_step := tween.tween_property(self, "scale", Vector2.ONE * punch, PUNCH_TIME)
	punch_step.set_trans(Tween.TRANS_BACK).set_ease(Tween.EASE_OUT)

	# Then the spring back. Elastic rather than a plain ease, because the small
	# wobble at the end is what sells weight.
	var settle_step := tween.tween_property(self, "scale", Vector2.ONE, SETTLE_TIME)
	settle_step.set_delay(PUNCH_TIME).set_trans(Tween.TRANS_ELASTIC).set_ease(Tween.EASE_OUT)

	# The lean unwinds to a fraction of itself rather than to zero, so the text
	# keeps a hand-stamped tilt instead of snapping to level.
	var tilt_step := tween.tween_property(self, "rotation", lean * 0.2, PUNCH_TIME + SETTLE_TIME)
	tilt_step.set_trans(Tween.TRANS_ELASTIC).set_ease(Tween.EASE_OUT)

	# Most of the distance is covered in the first moments, then it coasts.
	var travel_step := tween.tween_property(self, "position", start + travel, hold_end)
	travel_step.set_trans(Tween.TRANS_QUINT).set_ease(Tween.EASE_OUT)

	# Blown out white for a couple of frames, then the real colour drops in.
	var flash_step := tween.tween_property(
		_label, "theme_override_colors/font_color", color, FLASH_TIME
	)
	flash_step.set_delay(PUNCH_TIME * 0.5)

	# Swelling while it fades makes the text disperse. Fading at a fixed size just
	# looks like the alpha was turned down.
	var swell_step := tween.tween_property(
		self, "scale", Vector2.ONE * EVAPORATE_SCALE, fade_time
	)
	swell_step.set_delay(hold_end).set_trans(Tween.TRANS_CUBIC).set_ease(Tween.EASE_IN)

	var fade_step := tween.tween_property(self, "modulate:a", 0.0, fade_time)
	fade_step.set_delay(hold_end).set_trans(Tween.TRANS_CUBIC).set_ease(Tween.EASE_IN)

	tween.finished.connect(queue_free)
