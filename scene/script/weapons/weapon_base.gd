class_name WeaponBase
extends Node2D
var actor: Node2D
var controller: Node
var active: bool = false
var supports_guard: bool = false
var aim_direction: Vector2 = Vector2.RIGHT

func configure(owner_actor: Node2D, weapon_controller: Node = null) -> void:
	actor = owner_actor
	controller = weapon_controller

func set_active(enabled: bool) -> void:
	active = enabled
	visible = enabled
	set_process(enabled)
	if not enabled: cancel_attack()

func aim(direction: Vector2) -> void:
	if not direction.is_zero_approx() and direction.is_finite(): aim_direction = direction.normalized()

func can_attack() -> bool:
	return active and is_instance_valid(actor) and not actor.is_queued_for_deletion() and actor.get("is_dead") != true

func attack(_direction: Vector2) -> bool:
	return false

func is_busy() -> bool:
	return false

func cancel_attack() -> void:
	pass

func reset_state() -> void:
	cancel_attack()
