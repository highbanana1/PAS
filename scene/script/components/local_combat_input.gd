class_name LocalCombatInput
extends Node
## Only this adapter reads mouse/weapon Input. Commands remain usable remotely.
var actor: Node2D
var controller: Node

func configure(owner_actor: Node2D, weapons: Node) -> void:
	actor = owner_actor
	controller = weapons

func enabled() -> bool:
	return is_instance_valid(actor) and actor.get("is_dead") != true and actor.get("is_locally_controlled") == true

func is_guard_requested() -> bool:
	return enabled() and controller.current_supports_guard() and Input.is_action_pressed("block")

func handle_event(event: InputEvent) -> bool:
	if not enabled(): return false
	if event is InputEventKey and event.echo: return false
	if event.is_action_pressed("weapon_slot_1"):
		if controller.current_weapon != 0: controller.equip_weapon(0)
		return true
	if event.is_action_pressed("weapon_slot_2"):
		if controller.current_weapon != 1: controller.equip_weapon(1)
		return true
	if event.is_action_pressed("weapon_next"):
		controller.cycle_weapon(1)
		return true
	if event.is_action_pressed("weapon_previous"):
		controller.cycle_weapon(-1)
		return true
	return false

func tick(delta: float) -> void:
	if not enabled(): return
	controller.aim(actor.get_global_mouse_position() - controller.get_aim_origin())
	var guard_requested := is_guard_requested()
	controller.set_guarding(guard_requested)
	if not guard_requested and Input.is_action_just_pressed("fire"):
		controller.attack(controller.aim_direction)
	controller.recover_guard(delta)
