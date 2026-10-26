class_name GuardComponent
extends Node
const Rules = preload("res://scene/script/combat/melee_guard_rules.gd")
signal changed(value: float, maximum: float)
signal guard_changed(enabled: bool)
signal blocked(direction: Vector2)
var actor: Node2D
var maximum: float = 100.0
var value: float = 100.0
var block_cost: float = 20.0
var duration: float = 10.0
var recovery_duration: float = 15.0
var angle: float = 140.0
var direction: Vector2 = Vector2.RIGHT
var is_guarding: bool = false
var hold_requested: bool = false
## Exhaustion survives button release and weapon switches until fully recovered.
var exhausted: bool = false

func configure(owner_actor: Node2D, rules: Dictionary = {}) -> void:
	actor = owner_actor
	apply_combat_rules(rules if not rules.is_empty() else Rules.new().to_authority_config().guard)
	reset_state()

func apply_combat_rules(rules: Dictionary) -> void:
	maximum = float(rules.get("maximum", maximum))
	block_cost = float(rules.get("block_cost", block_cost))
	duration = float(rules.get("duration", duration))
	recovery_duration = float(rules.get("recovery_duration", recovery_duration))
	angle = float(rules.get("angle", angle))

func request_guard(enabled: bool, facing: Vector2 = Vector2.ZERO) -> void:
	if not facing.is_zero_approx() and facing.is_finite(): direction = facing.normalized()
	hold_requested = enabled
	if value <= 0.0: exhausted = true
	_set_guard(enabled and is_instance_valid(actor) and actor.get("is_dead") != true and value > 0.0 and not exhausted)

func _set_guard(enabled: bool) -> void:
	if is_guarding == enabled: return
	is_guarding = enabled
	guard_changed.emit(enabled)

func try_block(context: RefCounted) -> bool:
	if context == null or not context.blockable or not is_guarding or exhausted or value <= 0.0: return false
	if not is_instance_valid(actor) or actor.get("is_dead") == true: return false
	var toward_attack: Vector2 = (context.origin - actor.global_position).normalized()
	if direction.dot(toward_attack) < cos(deg_to_rad(angle * 0.5)): return false
	value = maxf(value - block_cost, 0.0)
	changed.emit(value, maximum)
	blocked.emit(toward_attack)
	if value <= 0.0:
		exhausted = true
		_set_guard(false)
	return true

func tick(delta: float) -> void:
	if not is_instance_valid(actor) or actor.get("is_dead") == true or not is_finite(delta) or delta < 0.0: return
	if is_guarding:
		value = maxf(value - maximum * delta / maxf(duration, 0.1), 0.0)
		if is_zero_approx(value):
			value = 0.0
			exhausted = true
			_set_guard(false)
		changed.emit(value, maximum)
	elif exhausted or not hold_requested:
		var recovered := minf(value + maximum * delta / maxf(recovery_duration, 0.1), maximum)
		if is_equal_approx(recovered, maximum):
			recovered = maximum
			exhausted = false
		if not is_equal_approx(recovered, value):
			value = recovered
			changed.emit(value, maximum)

func reset_state() -> void:
	exhausted = false
	direction = Vector2.RIGHT
	value = maximum
	request_guard(false)
	changed.emit(value, maximum)

## Mirrors a host-authoritative checkpoint onto local presentation. No local
## input, timer or block result is allowed to overwrite these values in network
## mode; WeaponController suspends the local combat input adapter.
func apply_authority_state(state: Dictionary) -> void:
	if state.is_empty():
		return
	var new_maximum: Variant = state.get("maximum", maximum)
	if (new_maximum is float or new_maximum is int) and float(new_maximum) > 0.0:
		maximum = float(new_maximum)
	var new_value: Variant = state.get("value", value)
	if new_value is float or new_value is int:
		value = clampf(float(new_value), 0.0, maximum)
	var new_direction: Variant = state.get("direction", direction)
	if new_direction is Vector2 and (new_direction as Vector2).is_finite() \
			and not (new_direction as Vector2).is_zero_approx():
		direction = (new_direction as Vector2).normalized()
	exhausted = bool(state.get("exhausted", exhausted))
	hold_requested = bool(state.get("hold_requested", hold_requested))
	var new_guarding := bool(state.get("is_guarding", is_guarding))
	if is_guarding != new_guarding:
		_set_guard(new_guarding)
	changed.emit(value, maximum)
