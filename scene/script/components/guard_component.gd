class_name GuardComponent
extends Node
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

func configure(owner_actor: Node2D) -> void:
	actor = owner_actor
	value = maximum

func request_guard(enabled: bool, facing: Vector2 = Vector2.ZERO) -> void:
	if not facing.is_zero_approx() and facing.is_finite(): direction = facing.normalized()
	hold_requested = enabled
	_set_guard(enabled and is_instance_valid(actor) and actor.get("is_dead") != true and value > 0.0)

func _set_guard(enabled: bool) -> void:
	if is_guarding == enabled: return
	is_guarding = enabled
	guard_changed.emit(enabled)

func try_block(context: RefCounted) -> bool:
	if context == null or not context.blockable or not is_guarding or value <= 0.0: return false
	if not is_instance_valid(actor) or actor.get("is_dead") == true: return false
	var toward_attack: Vector2 = (context.origin - actor.global_position).normalized()
	if direction.dot(toward_attack) < cos(deg_to_rad(angle * 0.5)): return false
	value = maxf(value - block_cost, 0.0)
	changed.emit(value, maximum)
	blocked.emit(toward_attack)
	if value <= 0.0: _set_guard(false)
	return true

func tick(delta: float) -> void:
	if not is_instance_valid(actor) or actor.get("is_dead") == true or not is_finite(delta) or delta < 0.0: return
	if is_guarding:
		value = maxf(value - maximum * delta / maxf(duration, 0.1), 0.0)
		if is_zero_approx(value):
			value = 0.0
			_set_guard(false)
		changed.emit(value, maximum)
	elif not hold_requested:
		var recovered := minf(value + maximum * delta / maxf(recovery_duration, 0.1), maximum)
		if is_equal_approx(recovered, maximum): recovered = maximum
		if not is_equal_approx(recovered, value):
			value = recovered
			changed.emit(value, maximum)

func reset_state() -> void:
	value = maximum
	request_guard(false)
	changed.emit(value, maximum)
