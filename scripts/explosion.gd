extends Node2D

## A car coming apart, in the spot it died.
##
## Configured by assigning the fields before the node is added to the tree. It
## starts itself in _ready and frees itself at the end, so nothing has to own one
## of these or tick it; the same contract the score pops run on.
##
## Five things overlap, drawn back to front, and each is doing a specific job:
##
##   flash  - a light rather than a sprite. The track is lit, so for a few frames
##            the corner itself goes bright and the wreck is the brightest thing
##            on screen. Most of the punch is here and it costs one node.
##   smoke  - dark, slow, growing, and the last thing still on screen. It is what
##            leaves the corner looking like a run ended on it.
##   fire   - stacked discs that punch out white hot and cool down through the
##            hazard ramp. The read of the hit is in the first three frames of
##            this and nothing else.
##   debris - chunks in the car's own paint and in scorched metal, thrown along
##            the heading it died on. In a four-way pile-up whose wreck it is has
##            to be readable, which is why the paint goes on the chunks.
##   embers - single hot pixels, fast and short lived. They are what stops the
##            silhouette of the blast from being a clean circle.
##
## All of it is drawn by hand on whole-pixel positions instead of handed to a
## particle node, for the same reason the skid marks are: at this resolution a
## soft sub-pixel particle reads as a smudge, and a square one reads as debris.

## The hazard ramp, the same accents the combo tiers are named on: white hot in
## the middle, out through yellow and orange to red at the edge. The palette rule
## in the design document reserves these for things that can kill you, and this
## is the thing that just did.
const CORE := Color(1.0, 0.99, 0.94)
const HOT := Color(0.98, 0.85, 0.35)
const FLAME := Color(1.0, 0.68, 0.16)
const BURN := Color(1.0, 0.24, 0.18)
## Scorched bodywork. Dark enough to read as part of the car rather than part of
## the fire, which is what keeps the debris from looking like more sparks.
const METAL := Color(0.16, 0.15, 0.17)
const ASH := Color(0.29, 0.27, 0.30)

## How long the fireball lasts, the light flash with it, and the ring that runs
## out ahead of both. All short: the hit has to be over well before the car comes
## back, or the respawn lands in the middle of its own wreckage.
const FIRE_TIME := 0.30
const FLASH_TIME := 0.26
const RING_TIME := 0.34

## When the node gives up and frees itself. Has to outlast the longest-lived
## smoke puff below, since that is the last thing still being drawn.
const LIFE := 1.5

const CHUNK_COUNT := 12
const EMBER_COUNT := 16
const PUFF_COUNT := 7

## Share of the car's last velocity handed to the debris. Thrown out of a
## standstill the blast reads as a firework; thrown along the heading the car
## died on it reads as the car itself coming apart, which is what this is.
const MOMENTUM_SHARE := 0.45

## Share of a piece's life spent fading out. The rest is full opacity, so debris
## is legible for most of its flight instead of dimming from the moment it leaves.
const FADE_SHARE := 0.45

## The player's paint. Debris carries it so a wreck in a crowd still says whose
## it was.
var color := Color(0.9, 0.9, 0.95)
## Where the car was going, and how fast, when it hit.
var momentum := Vector2.ZERO

var _age := 0.0
var _chunks: Array[Dictionary] = []
var _embers: Array[Dictionary] = []
var _puffs: Array[Dictionary] = []

## One radial ramp shared by every blast there will ever be. Four cars piling into
## the same barrier must not build four identical textures.
static var _flash_ramp: GradientTexture2D


func _ready() -> void:
	# Fire and hot debris are emissive: they light the track, the track does not
	# light them. Left on the default mask a blast driven into an unlit corner
	# would come out dimmer than the same blast under the start line.
	light_mask = 0
	_seed_puffs()
	_seed_chunks()
	_seed_embers()
	_add_flash()


func _process(delta: float) -> void:
	_age += delta
	_advance(_puffs, delta)
	_advance(_chunks, delta)
	_advance(_embers, delta)
	queue_redraw()
	if _age >= LIFE:
		queue_free()


## Chunks alternate between the car's paint and scorched metal rather than
## rolling for it, so a wreck can never come out with no paint in it at all.
##
## The angles are spaced evenly and then jittered, for the same reason: twelve
## random directions cluster, and a cluster reads as the car having been hit from
## one side rather than having gone up.
func _seed_chunks() -> void:
	for i in CHUNK_COUNT:
		var angle := TAU * (float(i) + randf_range(-0.35, 0.35)) / CHUNK_COUNT
		var heading := Vector2.from_angle(angle)
		_chunks.append({
			"pos": heading * randf_range(1.0, 5.0),
			"vel": heading * randf_range(55.0, 165.0) + momentum * MOMENTUM_SHARE,
			"drag": 2.8,
			"size": randf_range(2.0, 4.0),
			"grow": 0.0,
			"angle": randf() * TAU,
			"spin": randf_range(-16.0, 16.0),
			"age": 0.0,
			"life": randf_range(0.7, 1.15),
			"color": color if i % 2 == 0 else METAL,
		})


## Single pixels, fast and gone quickly. Their whole job is the ragged edge on
## the first moments of the blast, so they get almost no drag and no spin worth
## seeing at one pixel across.
func _seed_embers() -> void:
	var ramp := [CORE, HOT, FLAME, BURN]
	for i in EMBER_COUNT:
		var heading := Vector2.from_angle(randf() * TAU)
		_embers.append({
			"pos": heading * randf_range(0.0, 3.0),
			"vel": heading * randf_range(120.0, 280.0) + momentum * MOMENTUM_SHARE * 0.5,
			"drag": 4.5,
			"size": randf_range(1.0, 2.0),
			"grow": 0.0,
			"angle": 0.0,
			"spin": 0.0,
			"age": 0.0,
			"life": randf_range(0.22, 0.5),
			"color": ramp[i % ramp.size()],
		})


## Slow, heavy, and growing the whole way. The smoke is the only part of this
## that is still there a second later, which makes it the part that says a run
## ended on this corner rather than somewhere else.
func _seed_puffs() -> void:
	for i in PUFF_COUNT:
		var heading := Vector2.from_angle(TAU * float(i) / PUFF_COUNT + randf_range(-0.4, 0.4))
		_puffs.append({
			"pos": heading * randf_range(0.0, 6.0),
			"vel": heading * randf_range(14.0, 38.0),
			"drag": 2.0,
			"size": randf_range(4.0, 7.0),
			"grow": randf_range(6.0, 11.0),
			"angle": randf() * TAU,
			"spin": randf_range(-1.2, 1.2),
			"age": 0.0,
			"life": randf_range(0.95, 1.35),
			"color": ASH,
		})


## Plain integration rather than anything analytic, because drag is the whole
## shape of the throw: pieces leave fast, lose it almost immediately and then
## drift, which is what makes the blast read as air resisting debris instead of
## dots sliding outward at a fixed rate.
func _advance(bits: Array[Dictionary], delta: float) -> void:
	for bit in bits:
		bit["age"] += delta
		bit["pos"] += bit["vel"] * delta
		bit["vel"] *= maxf(1.0 - bit["drag"] * delta, 0.0)
		bit["angle"] += bit["spin"] * delta


## Back to front. The ring goes over the fire rather than under it so it still
## reads once the fireball has swollen past where it started.
func _draw() -> void:
	_paint(_puffs)
	_draw_fire()
	_draw_ring()
	_paint(_chunks)
	_paint(_embers)


func _paint(bits: Array[Dictionary]) -> void:
	for bit in bits:
		var span: float = bit["life"]
		var t: float = bit["age"] / span
		if t >= 1.0:
			continue

		# Full opacity until the tail of the life, then out. Fading from the first
		# frame would leave nothing legible long enough to be seen as a piece of a
		# car rather than as a flicker.
		var fade := clampf((1.0 - t) / FADE_SHARE, 0.0, 1.0)
		var tint: Color = bit["color"]
		tint.a *= fade

		# Whole pixels, whole positions. The game is nearest-neighbour everywhere
		# else and a two-pixel chunk sitting on a half pixel is a four-pixel blur.
		var size := maxf(roundf(bit["size"] + bit["grow"] * bit["age"]), 1.0)
		var half := size * 0.5
		draw_set_transform(bit["pos"].round(), bit["angle"], Vector2.ONE)
		draw_rect(Rect2(-half, -half, size, size), tint)

	draw_set_transform(Vector2.ZERO, 0.0, Vector2.ONE)


## Four discs cooling from the inside out: the white core burns off first, the
## red edge outlives all of it. They swell fast and then hold, and the collapse
## is done entirely with alpha, because a fireball that shrinks back to a point
## reads as a balloon deflating.
func _draw_fire() -> void:
	var t := _age / FIRE_TIME
	if t >= 1.0:
		return
	var swell := 1.0 - pow(1.0 - t, 3.0)
	var left := 1.0 - t
	_disc(lerpf(7.0, 32.0, swell), BURN, pow(left, 1.4) * 0.85)
	_disc(lerpf(5.0, 22.0, swell), FLAME, pow(left, 2.0) * 0.95)
	_disc(lerpf(3.0, 13.0, swell), HOT, pow(left, 3.0))
	_disc(lerpf(2.0, 6.0, swell), CORE, pow(left, 4.5))


func _disc(radius: float, tint: Color, alpha: float) -> void:
	if alpha <= 0.02:
		return
	draw_circle(Vector2.ZERO, roundf(radius), Color(tint, alpha))


## One ring running out ahead of the fire and gone before it is. It is what gives
## the blast a size the eye can actually measure, which is most of why a hit at
## this scale registers as an event rather than a colour change.
func _draw_ring() -> void:
	var t := _age / RING_TIME
	if t >= 1.0:
		return
	var radius := roundf(lerpf(9.0, 48.0, 1.0 - pow(1.0 - t, 3.0)))
	# Not antialiased, in line with everything else drawn here.
	draw_arc(Vector2.ZERO, radius, 0.0, TAU, 32, Color(CORE, (1.0 - t) * 0.45), 2.0, false)


## The part that actually lands on the track: for a couple of frames the asphalt
## around the wreck is lit by it. Held at full for a beat before the decay, since
## a flash that starts falling on the frame it appears never reaches the eye.
func _add_flash() -> void:
	var light := PointLight2D.new()
	light.texture = _flash_texture()
	light.texture_scale = 1.5
	light.color = FLAME
	light.energy = 2.6
	add_child(light)

	var tween := create_tween()
	tween.tween_interval(FLASH_TIME * 0.2)
	var decay := tween.tween_property(light, "energy", 0.0, FLASH_TIME * 0.8)
	decay.set_trans(Tween.TRANS_EXPO).set_ease(Tween.EASE_OUT)
	tween.tween_callback(light.queue_free)


## A radial white ramp with the falloff biased toward the centre, so the light
## reads as a point source going off rather than a disc being switched on.
static func _flash_texture() -> GradientTexture2D:
	if _flash_ramp != null:
		return _flash_ramp

	var ramp := Gradient.new()
	ramp.set_color(0, Color(1.0, 1.0, 1.0, 1.0))
	ramp.set_color(1, Color(1.0, 1.0, 1.0, 0.0))
	ramp.add_point(0.35, Color(1.0, 1.0, 1.0, 0.5))

	_flash_ramp = GradientTexture2D.new()
	_flash_ramp.gradient = ramp
	_flash_ramp.fill = GradientTexture2D.FILL_RADIAL
	_flash_ramp.fill_from = Vector2(0.5, 0.5)
	_flash_ramp.fill_to = Vector2(1.0, 0.5)
	_flash_ramp.width = 128
	_flash_ramp.height = 128
	return _flash_ramp
