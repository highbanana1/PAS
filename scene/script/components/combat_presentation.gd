class_name CombatPresentation
extends Node
const Feedback = preload("res://scene/script/combat_feedback.gd")
var _actor: Node2D
var _guard: Node

func configure(actor: Node2D, _weapons: Node, guard: Node) -> void:
	if is_instance_valid(_guard) and _guard.blocked.is_connected(_on_blocked): _guard.blocked.disconnect(_on_blocked)
	_actor = actor
	_guard = guard
	_guard.blocked.connect(_on_blocked)

func _on_blocked(direction: Vector2) -> void:
	if is_instance_valid(_actor): Feedback.show_block(_actor, direction)
