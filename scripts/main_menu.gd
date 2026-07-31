extends Control

## Two ways into a race, and the co-op lobby that one of them opens.
##
## Deliberately unstyled: default theme, default fonts, no art. It is here to
## make the mode choice reachable, not to be the front of the game.
##
## The lobby is a sibling panel rather than a second scene, because everything
## it collects is thrown away if the player backs out, and a scene change is a
## clumsy way to say "never mind".

const ARENA := "res://scenes/arena.tscn"

@onready var _menu: CenterContainer = $Menu
@onready var _singleplayer: Button = $Menu/Options/Singleplayer
@onready var _lobby := $Lobby


func _ready() -> void:
	_singleplayer.pressed.connect(_on_singleplayer)
	$Menu/Options/Coop.pressed.connect(_on_coop)
	_lobby.cancelled.connect(_show_menu)
	_lobby.ready_to_race.connect(_on_ready_to_race)
	_show_menu()


func _show_menu() -> void:
	_lobby.close()
	_menu.visible = true
	# Focus so the menu is navigable on a pad: Godot's built-in ui_up, ui_down
	# and ui_accept already carry joypad events, but only to whatever has focus.
	_singleplayer.grab_focus()


func _on_singleplayer() -> void:
	PlayerConfig.start_singleplayer()
	_race()


func _on_coop() -> void:
	_menu.visible = false
	_lobby.open()


func _on_ready_to_race(players: Array) -> void:
	PlayerConfig.start_coop(players)
	_race()


func _race() -> void:
	get_tree().change_scene_to_file(ARENA)
