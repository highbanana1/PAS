extends RefCounted
## Host-owned guard resource and facing. Commands only supply intent; every
## value, direction, exhaustion lock and block result is decided here.

const Rules = preload("res://scene/script/combat/melee_guard_rules.gd")

var _rules: Dictionary = Rules.new().to_authority_config().guard
var maximum: float = Rules.DEFAULT_GUARD_MAXIMUM
var value: float = Rules.DEFAULT_GUARD_MAXIMUM
var block_cost: float = Rules.DEFAULT_GUARD_BLOCK_COST
var duration: float = Rules.DEFAULT_GUARD_DRAIN
var recovery_duration: float = Rules.DEFAULT_GUARD_RECOVERY
var angle: float = Rules.DEFAULT_GUARD_ARC
var direction: Vector2 = Vector2.RIGHT
var is_guarding: bool = false
var hold_requested: bool = false
var exhausted: bool = false
var life_id: int = 1
var revision: int = 0

func configure(rules: Dictionary, next_life: int = life_id) -> void:
	_rules = (rules if not rules.is_empty() else Rules.new().to_authority_config().guard).duplicate(true)
	reset(next_life)

func request(enabled: bool, facing: Vector2, alive: bool, current_life: int) -> bool:
	if current_life != life_id or not alive:
		return false
	if facing.is_finite() and not facing.is_zero_approx():
		direction = facing.normalized()
	elif enabled:
		return false
	hold_requested = enabled
	if value <= 0.0:
		exhausted = true
	_set_guard(enabled and value > 0.0 and not exhausted)
	revision += 1
	return true

## Advances drain or recovery. Returns true when the authoritative guard state
## changed in a way that must be checkpointed immediately.
func tick(delta: float) -> bool:
	if not is_finite(delta) or delta <= 0.0:
		return false
	var before_value := value
	var before_guard := is_guarding
	var before_exhausted := exhausted
	if is_guarding:
		value = maxf(value - maximum * delta / maxf(duration, 0.1), 0.0)
		if is_zero_approx(value):
			value = 0.0
			exhausted = true
			_set_guard(false)
	elif exhausted or not hold_requested:
		var recovered := minf(value + maximum * delta / maxf(recovery_duration, 0.1), maximum)
		if is_equal_approx(recovered, maximum):
			recovered = maximum
			exhausted = false
		value = recovered
	var changed := not is_equal_approx(before_value, value) \
		or before_guard != is_guarding \
		or before_exhausted != exhausted
	if changed:
		revision += 1
	return changed

func try_block(toward_attack: Vector2, alive: bool) -> Dictionary:
	if not alive or not is_guarding or exhausted or value <= 0.0:
		return {"blocked": false}
	if not toward_attack.is_finite() or toward_attack.is_zero_approx():
		return {"blocked": false}
	var toward := toward_attack.normalized()
	if direction.dot(toward) < cos(deg_to_rad(angle * 0.5)):
		return {"blocked": false}
	value = maxf(value - block_cost, 0.0)
	if value <= 0.0:
		exhausted = true
		_set_guard(false)
	revision += 1
	return {
		"blocked": true,
		"value": value,
		"maximum": maximum,
		"exhausted": exhausted,
		"broke": not is_guarding,
		"direction": direction,
	}

## Attack-cancels-guard: the swing lowers the blade and clears held intent, so a
## later tick cannot silently raise it again.
func cancel() -> bool:
	var changed := is_guarding or hold_requested
	hold_requested = false
	_set_guard(false)
	if changed:
		revision += 1
	return changed

func reset(next_life: int = life_id) -> void:
	life_id = next_life
	maximum = float(_rules.get("maximum", Rules.DEFAULT_GUARD_MAXIMUM))
	value = maximum
	block_cost = float(_rules.get("block_cost", Rules.DEFAULT_GUARD_BLOCK_COST))
	duration = float(_rules.get("duration", Rules.DEFAULT_GUARD_DRAIN))
	recovery_duration = float(_rules.get("recovery_duration", Rules.DEFAULT_GUARD_RECOVERY))
	angle = float(_rules.get("angle", Rules.DEFAULT_GUARD_ARC))
	direction = Vector2.RIGHT
	hold_requested = false
	exhausted = false
	is_guarding = false
	revision += 1

func get_state() -> Dictionary:
	return {
		"life_id": life_id,
		"value": value,
		"maximum": maximum,
		"block_cost": block_cost,
		"duration": duration,
		"recovery_duration": recovery_duration,
		"angle": angle,
		"direction": direction,
		"is_guarding": is_guarding,
		"hold_requested": hold_requested,
		"exhausted": exhausted,
		"revision": revision,
	}

func _set_guard(enabled: bool) -> void:
	is_guarding = enabled
