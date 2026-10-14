class_name CombatReceiver
extends Node

const Context = preload("res://scene/script/combat/attack_context.gd")
signal attack_received(context: RefCounted, result: int)
var actor: Node2D
var health: Node
var _guard: Callable

func configure(owner_actor: Node2D, health_component: Node, block_handler: Callable = Callable()) -> void:
	actor = owner_actor
	health = health_component
	_guard = block_handler

func receive_attack(context: RefCounted) -> int:
	if context == null or not is_instance_valid(actor) or not is_instance_valid(health): return Context.Result.IGNORED
	if not is_finite(context.amount) or context.amount <= 0.0 or not context.origin.is_finite(): return Context.Result.IGNORED
	if health.current <= 0.0 or actor.get("is_dead") == true: return Context.Result.IGNORED
	var result: int
	if context.blockable and _guard.is_valid() and _guard.call(context.origin):
		result = Context.Result.BLOCKED
	else:
		health.apply_damage(context.amount)
		result = Context.Result.KILLED if health.current <= 0.0 else Context.Result.DAMAGED
	attack_received.emit(context, result)
	return result

static func deliver(target: Node2D, context: RefCounted) -> int:
	if not is_instance_valid(target) or target.is_queued_for_deletion(): return Context.Result.IGNORED
	if not target.has_method("get_combat_receiver"): return Context.Result.IGNORED
	var receiver = target.get_combat_receiver()
	if not is_instance_valid(receiver): return Context.Result.IGNORED
	return receiver.receive_attack(context)
