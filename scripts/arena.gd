extends Node2D

## Temporary test harness: fixed camera, a generated track, a speed readout and
## the banked drift score. Press respawn to put the car back on the start line.

const CarScript := preload("res://scripts/car.gd")
const ScoreScript := preload("res://scripts/drift_score.gd")

@onready var car: CarScript = $Car
@onready var track := $Track
@onready var skid_marks := $SkidMarks
@onready var drift_score: ScoreScript = $DriftScore
@onready var readout: Label = $HUD/Readout
@onready var score_readout: Label = $HUD/Score

var spawn_point: Transform2D


func _ready() -> void:
	# Track builds itself in its own _ready, which runs before this one.
	spawn_point = track.get_spawn()
	car.reset(spawn_point)
	car.crashed.connect(_on_car_crashed)
	# Every rebuild, not just the one below, so this keeps holding once the track
	# starts regenerating on its own every few laps.
	track.rebuilt.connect(skid_marks.clear)

	# Controls scale out of their top-left corner unless told otherwise, which
	# would make the punch below throw the number sideways instead of swelling it
	# in place.
	score_readout.pivot_offset = score_readout.size * 0.5
	drift_score.score_changed.connect(_on_score_changed)


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


## The banked total only ever moves when a combo lands, so every change is worth
## a kick. The world-space meter carries the pending number; this is the safe one.
func _on_score_changed(total: int) -> void:
	score_readout.text = ScoreScript.grouped(total)
	var tween := create_tween()
	tween.tween_property(score_readout, "scale", Vector2.ONE * 1.3, 0.08).set_ease(Tween.EASE_OUT)
	var settle := tween.tween_property(score_readout, "scale", Vector2.ONE, 0.32)
	settle.set_trans(Tween.TRANS_ELASTIC).set_ease(Tween.EASE_OUT)


func _on_car_crashed() -> void:
	# Placeholder for the real instant-death handling. The combo is not dealt with
	# here: the score watches the same signal and drops it on its own.
	car.reset(spawn_point)
