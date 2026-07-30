extends CharacterBody2D

## Arcade top-down car. Micro Machines snappy, not simulation.
##
## The car is described by three numbers: how fast it is going, which way it is
## travelling, and how far the nose is swung off that travel line.
##
##   travel_yaw  - the direction the car actually moves. Velocity is ALWAYS
##                 exactly along this, so there is never any leftover momentum
##                 pulling the car somewhere it was not pointed. That is what
##                 kills floatiness.
##   drift_angle - how far the nose is kicked out from the travel line. Zero
##                 while gripping. Springs out when the drift button goes down
##                 and springs back when it comes up.
##
## Sprite rotation is travel_yaw + drift_angle. Cornering while drifting comes
## from drift_angle dragging travel_yaw around: the more sideways the nose, the
## harder the car arcs. Speed is untouched by any of it, so a drift preserves
## momentum instead of scrubbing it.
##
## Angles follow Godot 2D: 0 faces right, positive turns clockwise on screen.
## Distances are pixels.

signal crashed

@export_group("Engine")
## Very high on purpose. The car should leap, not build up.
@export var engine_power := 240.0
@export var max_speed := 190.0
@export var brake_power := 290.0
@export var reverse_power := 105.0
@export var max_reverse_speed := 38.0
## Slowdown when off both pedals. Low enough that feathering the gas is a real
## tool rather than an instant stop.
@export var coast_friction := 32.0

@export_group("Steering")
## Grip turn rate in radians/sec at low speed.
@export var steer_rate := 3.0
## Grip turn rate at top speed, as a share of steer_rate. Below 1.0 this is the
## whole reason the drift button exists: past a certain speed you physically
## cannot turn tight enough without breaking traction.
@export_range(0.05, 1.0) var high_speed_steer_factor := 0.50
## Speed at which steering reaches full strength. Stops the car pivoting in place.
@export var steer_speed_floor := 11.0
## Speed lost per second while cornering hard on grip, scaled by how far the
## stick is over and how fast you are going. This is what makes the drift worth
## using: without it, gripping a corner is free and drifting is pure downside.
@export var corner_scrub := 140.0

@export_group("Drift")
## Speed needed to break traction. Once drifting, only releasing the button ends it.
@export var drift_entry_speed := 30.0
## How far the nose can swing off the travel line.
@export var max_drift_angle_degrees := 52.0
## How hard the tail is pulled toward its target angle when traction breaks.
## This is a spring, so the nose accelerates out of line and eases into the
## angle instead of travelling at one flat rate and stopping dead. Higher
## breaks traction faster.
@export var drift_break_stiffness := 120.0
## Same, for the return to straight when the button is released. Kept higher
## than the break so recovery still feels immediate.
@export var drift_recover_stiffness := 90.0
## 1.0 arrives with no overshoot. Slightly under lets the tail wag a little past
## the angle before settling, which sells the weight transfer.
@export_range(0.4, 1.5) var drift_damping_ratio := 0.9
## How hard the car arcs at full drift angle, in radians/sec.
@export var drift_turn_rate := 3.4
## Speed lost per second while sliding. 0 preserves momentum completely, which
## is what the design calls for. Compare against corner_scrub: the gap between
## the two is exactly how much a drift is worth.
@export var drift_speed_scrub := 0.0

@export_group("Rumble")
## Controller shake at full drift angle. Weak motor only, so it reads as tyre
## chatter under the hands instead of an event.
@export_range(0.0, 1.0) var drift_rumble := 0.35
## Floor on that shake, as a share of drift_rumble. Without it the rumble fades
## to nothing at shallow angles and the drift feels like it stopped.
@export_range(0.0, 1.0) var drift_rumble_floor := 0.45
## Both motors, once, when the run ends.
@export_range(0.0, 1.0) var crash_rumble := 1.0
@export var crash_rumble_duration := 0.4

## The vibration call is a one-shot with a duration on it, so a sustained rumble
## has to be topped up. Doing that every physics frame floods the driver, so it
## gets re-issued on this interval with twice the duration and simply overlaps.
const RUMBLE_REFRESH := 0.1

var speed := 0.0
var travel_yaw := 0.0
var drift_angle := 0.0
var is_drifting := false

var _drift_angular_velocity := 0.0
var _drift_rumble_timer := 0.0
var _crash_rumble_left := 0.0

@onready var _brake_lights: Node2D = $BrakeLights


func _ready() -> void:
	travel_yaw = global_rotation


func _physics_process(delta: float) -> void:
	var steer := Input.get_axis("steer_left", "steer_right")
	var throttle := Input.get_action_strength("accelerate")
	var brake := Input.get_action_strength("brake")

	# Drift state is decided first so the speed rules below know which set to
	# apply this frame rather than last frame's.
	_update_drift(steer, delta)
	_update_speed(steer, throttle, brake, delta)
	_update_travel(steer, delta)
	_brake_lights.visible = brake > 0.0
	_update_rumble(delta)

	global_rotation = travel_yaw + drift_angle
	velocity = Vector2.from_angle(travel_yaw) * speed
	move_and_slide()
	_check_crash()


func _update_speed(steer: float, throttle: float, brake: float, delta: float) -> void:
	if throttle > 0.0:
		speed += engine_power * throttle * delta

	if brake > 0.0:
		if speed > 3.0:
			speed -= brake_power * brake * delta
		else:
			speed -= reverse_power * brake * delta  # rolling backwards

	if is_zero_approx(throttle) and is_zero_approx(brake):
		speed = move_toward(speed, 0.0, coast_friction * delta)

	_scrub_for_cornering(steer, delta)

	speed = clampf(speed, -max_reverse_speed, max_speed)


## Turning costs speed on grip and nothing in a drift. That asymmetry is the
## entire reason to touch the drift button: gripping a corner is precise but
## bleeds momentum, drifting carries it through.
##
## Grip scrub scales with steering and with speed, because the load a tyre is
## fighting goes with lateral acceleration, which is speed times turn rate. It
## also means slow manoeuvring stays free instead of feeling sticky.
func _scrub_for_cornering(steer: float, delta: float) -> void:
	if is_drifting:
		if drift_speed_scrub > 0.0:
			speed = move_toward(speed, 0.0, drift_speed_scrub * delta)
		return

	if corner_scrub <= 0.0:
		return
	var load := absf(steer) * clampf(absf(speed) / max_speed, 0.0, 1.0)
	speed = move_toward(speed, 0.0, corner_scrub * load * delta)


## Entry is gated on speed. Staying in a drift is gated on nothing: the only
## thing that ends it is the player letting go of the button.
func _update_drift(steer: float, delta: float) -> void:
	var held := Input.is_action_pressed("drift")
	if held and not is_drifting:
		if absf(speed) >= drift_entry_speed:
			is_drifting = true
	elif not held:
		is_drifting = false

	var target := steer * deg_to_rad(max_drift_angle_degrees) if is_drifting else 0.0
	var stiffness := drift_break_stiffness if is_drifting else drift_recover_stiffness
	var damping := 2.0 * drift_damping_ratio * sqrt(stiffness)
	var accel := (target - drift_angle) * stiffness - _drift_angular_velocity * damping
	_drift_angular_velocity += accel * delta
	drift_angle += _drift_angular_velocity * delta


func _update_travel(steer: float, delta: float) -> void:
	if absf(speed) < 3.0:
		return
	var direction := signf(speed)  # steering inverts in reverse

	if is_drifting:
		# The slide is the steering. How far the nose is swung sets how hard the
		# car comes round, so a full-lock drift clears a hairpin and a light one
		# only trims the line.
		var commitment := drift_angle / deg_to_rad(max_drift_angle_degrees)
		travel_yaw += commitment * drift_turn_rate * direction * delta
	else:
		var pace := clampf(absf(speed) / max_speed, 0.0, 1.0)
		var rate := lerpf(steer_rate, steer_rate * high_speed_steer_factor, pace)
		rate *= clampf(absf(speed) / steer_speed_floor, 0.0, 1.0)
		travel_yaw += steer * rate * direction * delta


## Tyre chatter while the car is sideways, scaled by how far out the nose is.
## The crash hit takes priority: while its lockout runs, nothing else is allowed
## to issue a vibration and cut it short.
func _update_rumble(delta: float) -> void:
	if _crash_rumble_left > 0.0:
		_crash_rumble_left -= delta
		return

	var want := 0.0
	if is_drifting:
		want = drift_rumble * lerpf(drift_rumble_floor, 1.0, slide_ratio())

	if want > 0.0:
		_drift_rumble_timer -= delta
		if _drift_rumble_timer <= 0.0:
			_drift_rumble_timer = RUMBLE_REFRESH
			_shake(want, 0.0, RUMBLE_REFRESH * 2.0)
	elif not is_zero_approx(_drift_rumble_timer):
		_drift_rumble_timer = 0.0
		_stop_shake()


## Every connected pad, so it works whichever port the controller landed on and
## quietly does nothing on keyboard.
func _shake(weak: float, strong: float, duration: float) -> void:
	for device in Input.get_connected_joypads():
		Input.start_joy_vibration(device, weak, strong, duration)


func _stop_shake() -> void:
	for device in Input.get_connected_joypads():
		Input.stop_joy_vibration(device)


## Touching a barrier ends the run. Only bodies in the "wall" group count, so
## car-to-car contact stays harmless once there are opponents.
func _check_crash() -> void:
	for i in get_slide_collision_count():
		var collider := get_slide_collision(i).get_collider() as Node
		if collider and collider.is_in_group("wall"):
			_crash()
			return


## Rumble is armed before the signal goes out, because whatever handles the
## crash is going to reset the car on the spot and that must not wipe the hit.
func _crash() -> void:
	_crash_rumble_left = crash_rumble_duration
	_shake(crash_rumble, crash_rumble, crash_rumble_duration)
	crashed.emit()


func reset(to: Transform2D) -> void:
	global_transform = to
	travel_yaw = global_rotation
	drift_angle = 0.0
	_drift_angular_velocity = 0.0
	speed = 0.0
	is_drifting = false
	velocity = Vector2.ZERO
	_drift_rumble_timer = 0.0


## How sideways the car is, 0-1. Hook for tyre smoke, skid marks and near-miss
## scrap scoring later.
func slide_ratio() -> float:
	return clampf(absf(drift_angle) / deg_to_rad(max_drift_angle_degrees), 0.0, 1.0)
