extends CanvasLayer

## Drives the diamond wipe that hides one track being swapped for the next.
##
## A run is two halves. The cover half grows the diamonds until the screen is
## solid, and at that instant `covered` fires: this is the one frame on which the
## old track can be torn down and the new one built without any of it showing.
## The reveal half shrinks them back to nothing.
##
## Whatever listens to `covered` also gets the wipe for free as a fix for a
## subtler problem. A track rebuilt straight out of the finish trigger runs while
## the physics server is mid-flush, which it forbids. `covered` fires from a tween
## step, i.e. on an idle frame, so the rebuild hung off it lands safely clear of
## that flush.

## The screen is fully black and the swap can happen. Fires once per play, at the
## turn between covering and revealing.
signal covered

## The wipe has fully retracted and the new track is on show.
signal finished

## Seconds each half of the wipe takes. The cover is a touch quicker than the
## reveal so the screen commits to black fast and then opens up more gently onto
## whatever was built behind it.
@export var cover_time := 0.35
@export var reveal_time := 0.45

@onready var _screen: ColorRect = $Screen

var _material: ShaderMaterial
var _running := false


func _ready() -> void:
	_material = _screen.material as ShaderMaterial
	# Starts fully open and out of the way. mouse_filter is set in the scene so
	# the transparent rect never eats input while it is idle.
	_set_progress(0.0)
	visible = false


## Runs the full wipe. Ignores a second call while one is already under way, so a
## double lap trigger cannot start two overlapping sweeps.
func play() -> void:
	if _running:
		return
	_running = true
	visible = true

	var tween := create_tween()
	tween.tween_method(_set_progress, 0.0, 1.0, cover_time).set_ease(Tween.EASE_IN)
	# The swap point. Emitted from inside the tween, so it lands on an idle frame
	# rather than in the physics flush the lap trigger fired from.
	tween.tween_callback(func() -> void: covered.emit())
	tween.tween_method(_set_progress, 1.0, 0.0, reveal_time).set_ease(Tween.EASE_OUT)
	tween.tween_callback(_end)


## True from the moment a wipe starts until it has fully retracted. Callers gate
## input on this so the car cannot be driven behind the cover.
func is_playing() -> bool:
	return _running


func _end() -> void:
	visible = false
	_running = false
	finished.emit()


func _set_progress(value: float) -> void:
	if _material != null:
		_material.set_shader_parameter("progress", value)
