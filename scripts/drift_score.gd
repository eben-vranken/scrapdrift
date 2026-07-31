extends Node

## Scoring for drifts, built on the Tony Hawk combo rather than a running total.
##
## The shape of it:
##
##   A drift earns points for as long as it lasts. Those points do not go into
##   the score, they go into a pending combo.
##   Ending a drift and starting another one soon enough links them. Each link
##   raises the multiplier, and the pending points keep stacking.
##   Driving clean for longer than the link window lands the combo: pending
##   points times multiplier are banked into the score for good.
##   Crashing loses the whole pending combo.
##
## That last pair is the entire point. A banked combo is safe and a pending one
## is not, so a long chain is the player choosing to keep risking a bigger and
## bigger number on a track where one wall tap ends the run. Nothing here needs
## to punish a bad drift: the combo does it, by being lost.
##
## Points accrue at a rate scaled by both how sideways the car is and how fast it
## is going, so a lazy donut in the infield is worth almost nothing and a
## committed slide through a fast corner is worth a lot. The car's own rules
## already make the second one the dangerous option.
##
## The escalating tier names are hung off the multiplier, not off any one slide
## and not off points either. Corners here top out at 180 degrees, so no single
## drift lasts long enough to climb a ladder worth having, and points earned vary
## with how fast the corner happened to be taken. The count of linked drifts does
## not: it is the one number that means the same thing on every corner of every
## track, which makes it the only honest thing to name a tier after.
##
## This node holds no references to anything visual. It is fed a car and emits
## what happened; the popups and the HUD read it. Bonuses from elsewhere in the
## game go in through add_bonus, which is how near-miss scrap will land in the
## same combo instead of in a separate system.

const CarScript := preload("res://scripts/car.gd")

## The combo grew long enough to earn a louder name for itself.
signal tier_reached(tier: String, color: Color, index: int)

## A drift ended. Points are what that single drift was worth, before multiplier.
signal drift_ended(points: int, multiplier: int)

## A drift was linked onto the last one and the multiplier went up.
signal chain_raised(multiplier: int)

## Something outside the drift added to the pending combo.
signal bonus_scored(label: String, points: int)

## The combo landed. Points are what went into the score, multiplier included.
signal combo_banked(points: int, multiplier: int)

## The combo was lost. Points are what it would have been worth had it landed,
## which is the number worth showing: it is what the crash actually cost.
signal combo_lost(points: int)

signal score_changed(score: int)

## The car being scored. Assigned before this node enters the tree: the arena
## spawns one score per player alongside the car it belongs to, so there is no
## fixed place in the scene to point a path at.
var car: CarScript

@export_group("Earning")
## Points per second at full lock and top speed. Everything below is expressed in
## these points, so this is the one dial that rescales the whole economy.
@export var drift_rate := 240.0
## How sideways the car has to be before a slide counts as a drift at all. Held
## at the same value as the skid marks' threshold on purpose: if it is leaving
## rubber it is scoring, and if it is not it is not.
@export_range(0.0, 1.0) var min_slide := 0.25
## Share of the rate still earned at a standstill. Zero would mean a slide that
## bleeds speed stops paying before it stops being a slide, which reads as the
## scoring having broken.
@export_range(0.0, 1.0) var slow_share := 0.15

@export_group("Chaining")
## How long after a drift ends another one can start and still count as linked.
## This is the real skill window: long enough to straighten up for a corner
## entry, short enough that a lap of ordinary driving cannot hold a combo open.
@export var link_window := 1.4
## Ceiling on the multiplier. Uncapped, a careful player on an easy track could
## chain indefinitely and make every other score irrelevant. Set to land on the
## last entry in tier_multipliers, so the top of the ladder and the top of the
## multiplier are the same moment rather than two separate anticlimaxes.
@export var max_multiplier := 25
## Shortest a drift can be and still count as a link. Without it, tapping the
## drift button repeatedly would ladder the multiplier for free.
@export var min_link_points := 25.0

@export_group("Tiers")
## Multiplier at which each name fires. Ascending. Evenly spaced so the ladder
## reads as a ladder: the player learns that another name is always five links
## away, whatever they are currently on.
@export var tier_multipliers: PackedInt32Array = [1, 5, 10, 15, 20, 25]
## Shouted at each step. Trimmed against the multipliers, so the shorter of the
## two decides how many tiers actually exist.
@export var tier_names: PackedStringArray = [
	"SLIDE", "SIDEWAYS!", "SCRAPPY!!", "UNHINGED!!!", "RUST DEVIL!!!!", "SCRAP GOD!!!!!"
]
## A heat ramp: bone, then up through the hazard accents, then past red into
## white hot for the top of the ladder. The palette rule in the design document
## reserves these for things that can kill you and things you can collect; a
## combo is both at once, which is the point of it.
@export var tier_colors: PackedColorArray = [
	Color(0.92, 0.89, 0.83),
	Color(0.98, 0.85, 0.35),
	Color(1.0, 0.68, 0.16),
	Color(1.0, 0.45, 0.12),
	Color(1.0, 0.24, 0.18),
	Color(1.0, 0.99, 0.94),
]

var score := 0

## Points banked into the combo so far, multiplier not yet applied.
var pending := 0.0
var multiplier := 1
## True from the first drift of a combo until it lands or is lost.
var combo_active := false

var _car: CarScript
var _was_drifting := false
## Counts down from link_window while not drifting. Reaching zero lands the combo.
var _link_left := 0.0
## Points earned by the drift currently under way. Only used to decide whether
## that drift was substantial enough to link; the tiers read the combo.
var _drift_points := 0.0
## Highest tier already shouted this combo, so each name fires once per chain
## rather than once per corner. Reset with the combo, not with the drift.
var _combo_tier := -1
## Whether the drift under way began inside a live link window. Only read once
## the drift ends, since that is when it is known to have been worth linking.
var _linked := false


func _ready() -> void:
	_car = car
	if _car == null:
		push_error("DriftScore: no car was assigned, nothing will be scored.")
		set_physics_process(false)
		return
	_car.crashed.connect(_on_car_crashed)


## On the physics tick because slide angle and speed are only meaningful at the
## rate the car itself updates them.
func _physics_process(delta: float) -> void:
	var sliding := _car.is_drifting and _car.slide_ratio() >= min_slide
	if sliding:
		_earn(delta)
	elif _was_drifting:
		_end_drift()
	else:
		_tick_link(delta)
	_was_drifting = sliding


func _earn(delta: float) -> void:
	if not _was_drifting:
		_begin_drift()

	var pace := clampf(absf(_car.speed) / _car.max_speed, 0.0, 1.0)
	var gain := drift_rate * _car.slide_ratio() * lerpf(slow_share, 1.0, pace) * delta
	_drift_points += gain
	pending += gain

	# Every other tier arrives when the multiplier moves, which happens as a drift
	# ends. The opening name is the exception: waiting for the end of the first
	# corner to say anything at all would leave the player sideways in silence, so
	# it lands as soon as this drift has proven it is not just a flick.
	if _drift_points >= min_link_points:
		_check_tier()


## A drift that starts inside a live link window is riding the combo rather than
## opening one. Whether that actually pays is decided at the other end, in
## _end_drift, so this only records the fact.
##
## The window is deliberately not cleared here. It is not ticked down during a
## drift either, so whatever was left of it survives the slide and a drift too
## short to count leaves the chain exactly where it found it.
func _begin_drift() -> void:
	# Only the drift's own tally resets here. The tier ladder belongs to the
	# combo and has to survive the gap between corners, or linking would never
	# climb it.
	_drift_points = 0.0
	_linked = combo_active and _link_left > 0.0
	combo_active = true


## Ending a drift does not land the combo. It opens the window in which the next
## drift can link, and only running that window out banks anything.
##
## The multiplier moves here rather than at the start of the drift, because only
## a finished drift can be measured. Raising it on the button going down would
## mean mashing the drift button laddered the multiplier for nothing.
func _end_drift() -> void:
	var counts := _drift_points >= min_link_points
	if counts:
		if _linked and multiplier < max_multiplier:
			multiplier += 1
			# The name before the number: on a tier link the shout is the reward
			# and the multiplier stamp is the receipt for it.
			_check_tier()
			# Ahead of drift_ended so the two can be shown together and the points
			# are already carrying the multiplier they earned.
			chain_raised.emit(multiplier)
		_link_left = link_window

	drift_ended.emit(roundi(_drift_points), multiplier)


func _tick_link(delta: float) -> void:
	if not combo_active:
		return
	_link_left -= delta
	if _link_left <= 0.0:
		_bank()


## Fires each step the multiplier has reached, one shout per tier per combo.
##
## Walks up rather than testing only the next step, so a tier table with gaps in
## it, or one edited to be finer than the multiplier can move in one link, still
## cannot leave a name stranded.
func _check_tier() -> void:
	var count := mini(tier_multipliers.size(), tier_names.size())
	while _combo_tier + 1 < count and multiplier >= tier_multipliers[_combo_tier + 1]:
		_combo_tier += 1
		tier_reached.emit(tier_names[_combo_tier], _tier_color(_combo_tier), _combo_tier)


func _tier_color(index: int) -> Color:
	if tier_colors.is_empty():
		return Color.WHITE
	return tier_colors[mini(index, tier_colors.size() - 1)]


func _bank() -> void:
	# Captured before the reset below, which puts multiplier back to 1. The points
	# already carry it, but the popup shows the multiplier alongside them, so it has
	# to be the one the combo actually landed on.
	var landed_multiplier := multiplier
	var earned := roundi(pending * multiplier)
	_reset_combo()
	if earned <= 0:
		return
	score += earned
	combo_banked.emit(earned, landed_multiplier)
	score_changed.emit(score)


## Banks the pending combo right now, wherever the link window happens to sit.
## For a hard stop like crossing the finish line: the run's drifts are cashed into
## the score then rather than left hanging on the clock or carried to the next
## track. A no-op when there is nothing pending.
func cash_in() -> void:
	_bank()


## Points that never make it into the score. The signal carries what the combo
## would have been worth so the player can be shown the size of the mistake.
func _on_car_crashed() -> void:
	if not combo_active:
		return
	var thrown_away := roundi(pending * multiplier)
	_reset_combo()
	combo_lost.emit(thrown_away)


func _reset_combo() -> void:
	pending = 0.0
	multiplier = 1
	combo_active = false
	_link_left = 0.0
	_drift_points = 0.0
	_combo_tier = -1
	_linked = false
	_was_drifting = false


## What the pending combo is currently worth if it lands. This is the number the
## live meter shows, and it is deliberately the optimistic one: watching it climb
## is what makes holding the chain tempting.
func pending_value() -> int:
	return roundi(pending * multiplier)


## How much of the link window is left, 1 down to 0. Full while a drift is
## actually under way, since nothing is running out during one.
##
## This is what the combo display flashes on: it is the only warning the player
## gets that the chain is about to land itself and stop growing.
func link_share() -> float:
	if not combo_active or _was_drifting:
		return 1.0
	if link_window <= 0.0:
		return 0.0
	return clampf(_link_left / link_window, 0.0, 1.0)


## Way in for anything outside the drift that should feed the same combo, such as
## the near-miss scrap the design document calls for. Points land in the pending
## pot, so a bonus taken mid-chain is worth the multiplier too.
func add_bonus(label: String, points: float) -> void:
	if points <= 0.0:
		return
	if not combo_active:
		combo_active = true
		_link_left = link_window
	pending += points
	bonus_scored.emit(label, roundi(points))


## Thousands separators. Six figure combos are the goal, and "127450" does not
## read as a reward at a glance the way "127,450" does. Lives here rather than
## with the popups because the HUD total has to be written the same way.
static func grouped(value: int) -> String:
	var digits := str(absi(value))
	var out := ""
	for i in digits.length():
		if i > 0 and (digits.length() - i) % 3 == 0:
			out += ","
		out += digits[i]
	return ("-" + out) if value < 0 else out


## Wipes the score outright. For starting a fresh run, not for a crash: a crash
## costs the combo, and what was already banked is what the run pays out.
func reset_run() -> void:
	_reset_combo()
	score = 0
	score_changed.emit(score)
