extends Control

## The couch co-op sign-in. Four seats, filled by whoever presses a button.
##
## Nothing here is bound through the InputMap, on purpose. The whole question
## this screen answers is "which device did that come from", and an action is
## the one thing that cannot tell you: it matches every device at once, which is
## exactly the ambiguity the per-player action sets exist to remove later. So
## raw events are read straight off _input and sorted by their device id, and
## PlayerConfig only builds the action sets once the field is known.
##
## A seat runs join -> pick a colour -> ready. The race starts the moment every
## seat that has been taken is ready, so the last player to press it is the one
## who starts it. Backing out un-readies, then leaves, then returns to the menu.
##
## Colours are exclusive. The design document's rule is that you must never lose
## your own car in a pack, and two players in the same paint is the one way to
## break that from inside the lobby, so a taken colour is skipped rather than
## shared.

## Somebody backed out of an empty lobby. The menu takes the screen back.
signal cancelled

## Everybody who joined is ready. Carries the field in grid order.
signal ready_to_race(players: Array)

const CarTexture := preload("res://textures/player.png")

## Sideways stick travel that counts as a colour change. Well past any resting
## drift, so a pad with a worn stick does not scroll the palette on its own.
const STICK_THRESHOLD := 0.6

## How big a car preview is drawn. The sprite is ten pixels wide, so it is being
## blown up a long way; the project filters nearest, which is what keeps it
## honest rather than smeared.
const PREVIEW_SIZE := Vector2(50.0, 70.0)

@onready var _slots_root: HBoxContainer = $Layout/Slots

## The field, in join order, which is also the grid order the arena spawns in.
## Each entry is {device, color, ready}, the shape PlayerConfig stores.
var _joined: Array[Dictionary] = []

## The four seats' controls, so a refresh writes into them rather than rebuilding
## the screen on every keypress.
var _seats: Array[Dictionary] = []

## Which way each device's stick is currently held, so holding it over steps the
## palette once rather than every frame. Keyed by device id.
var _stick := {}


func _ready() -> void:
	_build_seats()
	close()


func open() -> void:
	_joined.clear()
	_stick.clear()
	visible = true
	_refresh()


func close() -> void:
	visible = false


func _input(event: InputEvent) -> void:
	if not visible:
		return

	if event is InputEventJoypadButton and event.pressed:
		_pad_button(event.device, event.button_index)
	elif event is InputEventJoypadMotion:
		_pad_stick(event.device, event.axis, event.axis_value)
	elif event is InputEventKey and event.pressed and not event.echo:
		_key(event.keycode)
	else:
		return
	# Acting on the last ready press takes the lobby off the screen and starts
	# tearing the menu down, so there may no longer be a viewport to tell.
	var viewport := get_viewport()
	if viewport != null:
		viewport.set_input_as_handled()


func _pad_button(device: int, button: int) -> void:
	match button:
		JOY_BUTTON_A:
			_confirm(device)
		JOY_BUTTON_B:
			_back(device)
		JOY_BUTTON_DPAD_LEFT:
			_cycle_color(device, -1)
		JOY_BUTTON_DPAD_RIGHT:
			_cycle_color(device, 1)


## The left stick as a second way to pick a colour, latched so a held stick is
## one step rather than a scroll. Only the crossing into the deflection counts.
func _pad_stick(device: int, axis: int, value: float) -> void:
	if axis != JOY_AXIS_LEFT_X:
		return
	var direction := 0
	if value >= STICK_THRESHOLD:
		direction = 1
	elif value <= -STICK_THRESHOLD:
		direction = -1

	if _stick.get(device, 0) == direction:
		return
	_stick[device] = direction
	if direction != 0:
		_cycle_color(device, direction)


func _key(keycode: int) -> void:
	match keycode:
		KEY_SPACE, KEY_ENTER, KEY_KP_ENTER:
			_confirm(PlayerConfig.KEYBOARD)
		KEY_ESCAPE, KEY_BACKSPACE:
			_back(PlayerConfig.KEYBOARD)
		KEY_A, KEY_LEFT:
			_cycle_color(PlayerConfig.KEYBOARD, -1)
		KEY_D, KEY_RIGHT:
			_cycle_color(PlayerConfig.KEYBOARD, 1)


## Join if this device has no seat, ready up if it has one.
func _confirm(device: int) -> void:
	var seat := _seat_of(device)
	if seat < 0:
		_join(device)
		return
	if _joined[seat]["ready"]:
		return
	_joined[seat]["ready"] = true
	_refresh()
	_try_start()


## Un-ready, then leave, then out to the menu. A device with no seat has nothing
## to step back through, so it goes straight out: that is how a player who never
## joined, or one who has already left, gets off this screen.
func _back(device: int) -> void:
	var seat := _seat_of(device)
	if seat < 0:
		cancelled.emit()
		return
	if _joined[seat]["ready"]:
		_joined[seat]["ready"] = false
	else:
		_joined.remove_at(seat)
	_refresh()


func _join(device: int) -> void:
	if _joined.size() >= PlayerConfig.MAX_PLAYERS:
		return
	_joined.append({"device": device, "color": _first_free_color(), "ready": false})
	_refresh()


## Steps to the next colour nobody else is wearing. Walks rather than jumps so
## the palette still reads as an ordered strip with holes in it, and stops if
## somehow every colour is taken, which cannot happen with four of eight gone.
func _cycle_color(device: int, step: int) -> void:
	var seat := _seat_of(device)
	# Locked in once ready: changing paint from under a decision the player has
	# already made is how a lobby starts a race nobody agreed to.
	if seat < 0 or _joined[seat]["ready"]:
		return

	var count := PlayerConfig.COLORS.size()
	var index: int = _joined[seat]["color"]
	for _attempt in count:
		index = posmod(index + step, count)
		if not _color_taken(index, seat):
			_joined[seat]["color"] = index
			_refresh()
			return


func _first_free_color() -> int:
	for index in PlayerConfig.COLORS.size():
		if not _color_taken(index, -1):
			return index
	return 0


func _color_taken(index: int, except_seat: int) -> bool:
	for seat in _joined.size():
		if seat != except_seat and _joined[seat]["color"] == index:
			return true
	return false


func _seat_of(device: int) -> int:
	for seat in _joined.size():
		if _joined[seat]["device"] == device:
			return seat
	return -1


## An empty lobby is not a race. One player is allowed through: co-op with a
## single seat filled is just singleplayer taken the long way round, and
## refusing it would mean the screen cannot be tested without a second pad.
func _try_start() -> void:
	if _joined.is_empty():
		return
	for entry in _joined:
		if not entry["ready"]:
			return
	# Off the screen before the signal goes out, so nothing pressed during the
	# scene change lands back in a lobby that has already made its decision.
	close()
	ready_to_race.emit(_joined)


# --- the screen --------------------------------------------------------------


func _build_seats() -> void:
	for seat in PlayerConfig.MAX_PLAYERS:
		var box := VBoxContainer.new()
		box.custom_minimum_size = Vector2(150.0, 0.0)
		_slots_root.add_child(box)

		var title := Label.new()
		title.text = "P%d" % [seat + 1]
		title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		box.add_child(title)

		var preview := TextureRect.new()
		preview.texture = CarTexture
		preview.custom_minimum_size = PREVIEW_SIZE
		preview.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
		preview.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
		box.add_child(preview)

		var color_name := Label.new()
		color_name.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		box.add_child(color_name)

		var status := Label.new()
		status.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		box.add_child(status)

		_seats.append({
			"preview": preview,
			"color_name": color_name,
			"status": status,
		})


func _refresh() -> void:
	for seat in _seats.size():
		var controls: Dictionary = _seats[seat]
		var preview: TextureRect = controls["preview"]
		var color_name: Label = controls["color_name"]
		var status: Label = controls["status"]

		if seat >= _joined.size():
			preview.visible = false
			color_name.text = "-"
			status.text = "PRESS A / SPACE\nTO JOIN"
			continue

		var entry: Dictionary = _joined[seat]
		var color: Color = PlayerConfig.color_of(entry["color"])
		preview.visible = true
		preview.material = PlayerConfig.tint_material(color)
		color_name.text = PlayerConfig.color_name_of(entry["color"])
		# The device stays on screen once the seat is ready, so a player who has
		# put their pad down can still find which seat is theirs.
		status.text = "%s\n%s" % [
			_device_label(entry["device"]), "READY" if entry["ready"] else "PICKING"
		]


func _device_label(device: int) -> String:
	return "KEYBOARD" if device == PlayerConfig.KEYBOARD else "PAD %d" % device
