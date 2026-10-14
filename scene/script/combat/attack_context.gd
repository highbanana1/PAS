class_name AttackContext
extends RefCounted

enum Result { IGNORED, BLOCKED, DAMAGED, KILLED }
var amount: float
var origin: Vector2
var source: Node2D
var blockable: bool

func _init(damage: float = 0.0, attack_origin: Vector2 = Vector2.ZERO, attacker: Node2D = null, can_block: bool = true) -> void:
	amount = damage
	origin = attack_origin
	source = attacker
	blockable = can_block
