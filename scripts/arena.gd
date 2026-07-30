extends Node2D

## Temporary test harness: fixed camera, a generated track, and a speed readout.
## Press respawn to put the car back on the start line.

const CarScript := preload("res://scripts/car.gd")

@onready var car: CarScript = $Car
@onready var track := $Track
@onready var skid_marks := $SkidMarks
@onready var readout: Label = $HUD/Readout

var spawn_point: Transform2D


func _ready() -> void:
	# Track builds itself in its own _ready, which runs before this one.
	spawn_point = track.get_spawn()
	car.reset(spawn_point)
	car.crashed.connect(_on_car_crashed)
	# Every rebuild, not just the one below, so this keeps holding once the track
	# starts regenerating on its own every few laps.
	track.rebuilt.connect(skid_marks.clear)


func _process(_delta: float) -> void:
	var state := "DRIFT" if car.is_drifting else "GRIP"
	readout.text = "%3d km/h  %s" % [roundi(absf(car.speed) * 1.35), state]


func _unhandled_input(event: InputEvent) -> void:
	if event.is_action_pressed("respawn"):
		car.reset(spawn_point)
	elif event.is_action_pressed("regenerate"):
		track.generate()
		spawn_point = track.get_spawn()
		car.reset(spawn_point)


func _on_car_crashed() -> void:
	# Placeholder for the real instant-death handling.
	car.reset(spawn_point)
