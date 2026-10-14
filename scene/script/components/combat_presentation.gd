class_name CombatPresentation
extends Node
const Feedback = preload("res://scene/script/combat_feedback.gd")
const Context = preload("res://scene/script/combat/attack_context.gd")
var _actor: Node2D
var _weapons: Node
var _guard: Node

func configure(actor: Node2D, weapons: Node, guard: Node) -> void:
	if is_instance_valid(_weapons) and _weapons.attack_resolved.is_connected(_on_attack_resolved): _weapons.attack_resolved.disconnect(_on_attack_resolved)
	if is_instance_valid(_guard) and _guard.blocked.is_connected(_on_blocked): _guard.blocked.disconnect(_on_blocked)
	_actor = actor
	_weapons = weapons
	_guard = guard
	_weapons.attack_resolved.connect(_on_attack_resolved)
	_guard.blocked.connect(_on_blocked)

func _on_attack_resolved(target: Node2D, result: int) -> void:
	if not is_instance_valid(target): return
	if result == Context.Result.DAMAGED or result == Context.Result.KILLED:
		Feedback.show_hit(target, target.global_position)

func _on_blocked(direction: Vector2) -> void:
	if is_instance_valid(_actor): Feedback.show_block(_actor, direction)
