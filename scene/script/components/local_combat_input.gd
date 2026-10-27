class_name LocalCombatInput
extends Node
## Only this adapter reads mouse/weapon Input. In offline play it drives the
## local WeaponController exactly as before. When a MatchNetworkBridge binds
## intents, the same physical keys are collected but fire/sword/guard are only
## submitted as commands; the local controller never adjudicates them.
var actor: Node2D
var controller: Node

var _intent_bridge: Node = null
var _intent_player_id: StringName = &""
var _fire_down: bool = false
var _guard_submitted: bool = false
var _guard_direction: Vector2 = Vector2.RIGHT

func configure(owner_actor: Node2D, weapons: Node) -> void:
	actor = owner_actor
	controller = weapons

func bind_network_intents(bridge: Node, player_id: StringName) -> bool:
	if not is_instance_valid(bridge) or player_id == &"":
		return false
	_intent_bridge = bridge
	_intent_player_id = player_id
	_fire_down = Input.is_action_pressed("fire")
	_guard_submitted = false
	_guard_direction = Vector2.RIGHT
	return true

func clear_network_intents() -> void:
	_intent_bridge = null
	_intent_player_id = &""
	_fire_down = false
	_guard_submitted = false
	_guard_direction = Vector2.RIGHT

func uses_network_intents() -> bool:
	return is_instance_valid(_intent_bridge) and _intent_player_id != &""

func enabled() -> bool:
	if not is_instance_valid(actor) or actor.get("is_dead") == true \
			or actor.get("is_locally_controlled") != true:
		return false
	if is_instance_valid(controller) and controller.get("network_authority") == true:
		return uses_network_intents()
	return true

func is_guard_requested() -> bool:
	return enabled() and not uses_network_intents() \
		and controller.current_supports_guard() and Input.is_action_pressed("block")

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
	if uses_network_intents():
		_tick_network_intents()
		return
	# Offline path is unchanged: attack has priority over held defense and the
	# controller cancels guard first.
	if Input.is_action_just_pressed("fire"):
		controller.attack(controller.aim_direction)
	else:
		controller.set_guarding(is_guard_requested())
	controller.recover_guard(delta)

func _tick_network_intents() -> void:
	var fire_down := Input.is_action_pressed("fire")
	if fire_down and not _fire_down:
		_submit_attack_intent()
	_fire_down = fire_down
	var guard_down: bool = Input.is_action_pressed("block") and controller.current_supports_guard()
	var aim: Vector2 = controller.aim_direction
	var direction_changed: bool = guard_down and _guard_submitted \
		and aim.is_finite() and not aim.is_zero_approx() \
		and aim.normalized().dot(_guard_direction) < 0.999
	if guard_down != _guard_submitted or direction_changed:
		if _intent_bridge.submit_guard(guard_down, aim) >= 0:
			_guard_submitted = guard_down
			_guard_direction = aim

func _submit_attack_intent() -> void:
	if not uses_network_intents():
		return
	# Weapon choice itself is local presentation; the host still decides whether
	# the fire/sword command is legal and what it hits.
	if int(controller.current_weapon) == 1:
		_intent_bridge.submit_sword(controller.aim_direction)
	else:
		_intent_bridge.submit_fire(controller.aim_direction)
	# The authority cancels guard when it accepts the attack. Keep the local held
	# watermark until the button is released: transport submission is not proof
	# that a guard request sent during sword recovery was accepted by the host.
	# Releasing and pressing block again produces the next explicit guard intent.
