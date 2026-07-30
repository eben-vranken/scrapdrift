extends CanvasLayer

## Screen-space CRT and VHS pass.
##
## Sits on a high layer so it draws after everything else, which means the HUD
## gets the same treatment as the game and SCREEN_TEXTURE already holds the
## finished frame by the time the shader runs.
##
## Press toggle_crt (F) to flip it off. Worth having: judging a filter like this
## is much easier when you can A/B it against the raw image.

@onready var screen: ColorRect = $Screen


func _ready() -> void:
	_sync_resolution()
	get_viewport().size_changed.connect(_sync_resolution)


func _unhandled_input(event: InputEvent) -> void:
	if event.is_action_pressed("toggle_crt"):
		visible = not visible


## Hands the shader the viewport's logical size, which drives pixelation and the
## noise quantisation. get_visible_rect() rather than the window size, because
## with viewport stretch those differ: the window is 1920x1080 while the content
## this shader operates on is 960x540.
func _sync_resolution() -> void:
	var material := screen.material as ShaderMaterial
	if material == null:
		return
	material.set_shader_parameter("resolution", get_viewport().get_visible_rect().size)
