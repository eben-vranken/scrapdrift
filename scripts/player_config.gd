extends Node

## Who is racing, on which device, in which colour.
##
## This is an autoload for one reason: the lobby decides the field and the arena
## builds it, and those are two different scenes. Everything here is either what
## the menu wrote down or something derived from it.
##
## The input side is the other half of the job. Godot's actions are global and
## match every device at once, which is exactly wrong for couch co-op: one pad
## pulling the trigger would accelerate all four cars. So each player gets a
## private copy of the driving actions with its events bound to that player's
## pad, and a car reads "p2_accelerate" rather than "accelerate".
##
## The same trick is what fences off the debug controls. They are copied for
## player one and for nobody else, so restricting them takes no checks at the
## point of use: the other three seats are simply not bound to those actions and
## have nothing to press. The originals are left alone throughout, so the
## InputMap in the project settings stays the one place the bindings are
## authored.

## Seats on the couch. Four is the practical ceiling for pads and for the
## starting grid the arena lays out.
const MAX_PLAYERS := 4

## Stands in for the keyboard in a player's `device`. Godot numbers pads from
## zero, so anything negative is free for this.
const KEYBOARD := -1

## The actions copied for every player. One car each.
const DRIVING_ACTIONS: PackedStringArray = [
	"accelerate", "brake", "steer_left", "steer_right", "drift"
]

## Copied for player one alone. These act on the whole session rather than on
## one car: they throw the field back to the line, regenerate the track under
## everybody, or take the CRT pass off the screen. Shared, they are four people
## fighting over the same track in a living room. Owned by one seat, they are
## what they were always meant to be, which is the host's controls.
const DEBUG_ACTIONS: PackedStringArray = ["respawn", "regenerate", "toggle_crt"]

## Which seat holds them: the first to join the lobby, and the only seat there
## is in singleplayer.
const DEBUG_SLOT := 0

## Saturated and clearly distinct, per the design document's rule that you must
## never lose your own car in a pack. There are twice as many as there are seats
## so the last player to pick is still choosing rather than taking what is left.
const COLORS: PackedColorArray = [
	Color(0.98, 0.42, 0.04),
	Color(0.25, 0.55, 0.95),
	Color(0.61, 0.87, 0.20),
	Color(0.93, 0.28, 0.70),
	Color(0.98, 0.82, 0.18),
	Color(0.18, 0.82, 0.78),
	Color(0.62, 0.35, 0.95),
	Color(0.92, 0.89, 0.83),
]
const COLOR_NAMES: PackedStringArray = [
	"RUST", "COBALT", "ACID", "MAGENTA", "AMBER", "TEAL", "VIOLET", "BONE"
]

const TintShader := preload("res://shaders/car_tint.gdshader")

## How much lighter the body's highlight shade is than the body itself. Eyeballed
## against the gap between the two oranges the sprite is authored in.
const SHINE_LIFT := 0.28

## The field, in grid order. Each entry is {device, color, ready}: `device` is a
## pad index or KEYBOARD, `color` indexes COLORS, and `ready` is the lobby's and
## is simply carried along once the race starts.
var players: Array[Dictionary] = []

## Whether the field came out of the lobby. Drives the parts of the arena that
## only make sense with a crowd, such as the per-player board replacing the
## single big score.
var coop := false


## One player on the first pad, with the keyboard alongside it.
func start_singleplayer() -> void:
	coop = false
	players = [{"device": 0, "color": 0, "ready": true}]


func start_coop(joined: Array) -> void:
	coop = true
	players = []
	for entry in joined:
		players.append((entry as Dictionary).duplicate())


## Falls back to a singleplayer field if nothing has been through the menu. That
## is what makes arena.tscn still playable when it is run straight out of the
## editor, which is how most of this game gets tested.
func ensure_players() -> void:
	if players.is_empty():
		start_singleplayer()


## Rebuilds every player's action set from the shared originals. The arena calls
## this on the way in rather than trusting whatever the menu left behind, so
## reloading the scene re-binds instead of racing on a stale map.
func apply_input_map() -> void:
	_clear_generated()
	for slot in players.size():
		var device: int = players[slot]["device"]
		# Singleplayer keeps the keyboard on the one car, so the game is still
		# playable at a desk with nothing plugged in. In co-op the keyboard
		# belongs to whoever joined on it and to nobody else, or every keypress
		# would drive all four.
		var keyboard := device == KEYBOARD or not coop
		_bind(slot, device, keyboard, DRIVING_ACTIONS)
		if slot == DEBUG_SLOT:
			_bind(slot, device, keyboard, DEBUG_ACTIONS)


## What a car in this slot prefixes its action names with. Empty is not a valid
## answer here: an unbound car reading the shared actions would answer to every
## pad in the room.
func prefix_for(slot: int) -> String:
	return "p%d_" % slot


## What player one's copy of a session control is called. Whatever owns one of
## these reads it through here rather than naming the shared action, which is
## the whole mechanism: the other three seats are simply never bound to it, so
## there is nothing for them to press.
##
## Falls back to the shared action when the field has not been bound yet, so a
## scene opened on its own still toggles and regenerates instead of erroring on
## an action that does not exist.
func debug_action(action: String) -> String:
	var generated := prefix_for(DEBUG_SLOT) + action
	return generated if InputMap.has_action(generated) else action


func color_of(index: int) -> Color:
	return COLORS[posmod(index, COLORS.size())]


func color_name_of(index: int) -> String:
	return COLOR_NAMES[posmod(index, COLOR_NAMES.size())]


## A fresh material every call. Each car wears its own colour, so they cannot
## share one: setting a parameter on a shared material would repaint the field.
func tint_material(color: Color) -> ShaderMaterial:
	var material := ShaderMaterial.new()
	material.shader = TintShader
	material.set_shader_parameter("body_color", _rgb(color))
	material.set_shader_parameter("shine_color", _rgb(color.lightened(SHINE_LIFT)))
	return material


func _bind(slot: int, device: int, include_keyboard: bool, actions: PackedStringArray) -> void:
	for action in actions:
		var generated := prefix_for(slot) + action
		if InputMap.has_action(generated):
			InputMap.erase_action(generated)
		# The deadzone is copied too, or a stick bound per-device would suddenly
		# be reading raw values the shared action never saw.
		InputMap.add_action(generated, InputMap.action_get_deadzone(action))

		for event in InputMap.action_get_events(action):
			var copy: InputEvent = event.duplicate()
			if copy is InputEventKey:
				if not include_keyboard:
					continue
				# Left on the all-devices default: there is only one keyboard,
				# and pinning it to a device index is how you end up with a
				# layout that works on one machine.
			elif copy is InputEventJoypadButton or copy is InputEventJoypadMotion:
				if device < 0:
					continue
				copy.device = device
			InputMap.action_add_event(generated, copy)


## Wipes every slot's actions, not just the ones currently in use. A four player
## race followed by a singleplayer one would otherwise leave p1 through p3 bound
## and live, which is invisible until something reads them.
func _clear_generated() -> void:
	for slot in MAX_PLAYERS:
		for action in DRIVING_ACTIONS + DEBUG_ACTIONS:
			var generated := prefix_for(slot) + action
			if InputMap.has_action(generated):
				InputMap.erase_action(generated)


static func _rgb(color: Color) -> Vector3:
	return Vector3(color.r, color.g, color.b)
