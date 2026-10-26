extends SceneTree

const Rules = preload("res://scene/script/combat/melee_guard_rules.gd")
const Controller = preload("res://scene/script/weapon_controller.gd")
const Sword = preload("res://scene/script/sword.gd")
const Authority = preload("res://scene/script/network/match_authority.gd")
const Actor = preload("res://tests/fixtures/network_combat_actor.gd")

var failures: Array[String] = []

func _initialize() -> void:
	run.call_deferred()

func check(ok: bool, label: String) -> void:
	print(("PASS: " if ok else "FAIL: ") + label)
	if not ok: failures.append(label)

func actor_at(position: Vector2):
	var actor = Actor.new()
	actor.position = position
	root.add_child(actor)
	return actor

func custom_rules():
	var rules = Rules.new()
	rules.sword_damage = 7.0
	rules.sword_range = 64.0
	rules.sword_arc = 90.0
	rules.sword_windup = 0.1
	rules.sword_swing = 0.2
	rules.sword_recovery = 0.3
	rules.sword_cooldown = 0.6
	rules.guard_maximum = 80.0
	rules.guard_block_cost = 8.0
	rules.guard_drain_duration = 4.0
	rules.guard_recovery_duration = 6.0
	rules.guard_arc = 100.0
	return rules

func run() -> void:
	await test_validated_defaults_and_invalid_fallback()
	await test_offline_consumers_share_resource()
	await test_authority_uses_host_snapshot_and_ignores_forgery()
	await test_recovery_limits_attack_and_rules_survive_respawn()
	await test_long_cooldown_does_not_extend_guard_lock()
	await test_real_player_resource_reaches_host()
	print("RESULT: ", failures.size(), " failures")
	quit(0 if failures.is_empty() else 1)

func test_validated_defaults_and_invalid_fallback() -> void:
	var rules = Rules.new()
	var defaults: Dictionary = rules.to_authority_config()
	check(is_equal_approx(float(defaults.sword.damage), 2.0)
		and is_equal_approx(float(defaults.sword.range), 36.0)
		and is_equal_approx(float(defaults.guard.maximum), 100.0),
		"Shared rules preserve the existing defaults")
	rules.sword_damage = NAN
	rules.sword_range = -1.0
	rules.guard_maximum = 0.0
	var safe: Dictionary = rules.to_authority_config()
	check(is_equal_approx(float(safe.sword.damage), 2.0)
		and is_equal_approx(float(safe.sword.range), 36.0)
		and is_equal_approx(float(safe.guard.maximum), 100.0),
		"Invalid Inspector values fall back to safe existing defaults")
	var validated: Dictionary = Rules.validated_config({
		"sword": {"damage": INF, "range": "bad", "swing": 1e30},
		"guard": {"maximum": 0.0, "angle": -1.0},
	})
	check(is_equal_approx(float(validated.sword.damage), 2.0)
		and is_equal_approx(float(validated.sword.range), 36.0)
		and is_equal_approx(float(validated.sword.swing), 0.09)
		and is_equal_approx(float(validated.guard.maximum), 100.0)
		and is_equal_approx(float(validated.guard.angle), 140.0),
		"Programmatic host setup validates invalid and out-of-range values too")

func test_offline_consumers_share_resource() -> void:
	var actor = actor_at(Vector2.ZERO)
	var controller = Controller.new()
	controller.combat_rules = custom_rules()
	actor.add_child(controller)
	controller.configure(actor)
	var sword = Sword.new()
	var sprite := Sprite2D.new()
	sprite.name = "Sprite2D"
	sword.add_child(sprite)
	actor.add_child(sword)
	controller.register_weapon(1, sword)
	await process_frame
	var guard = controller.get_guard_component()
	check(is_equal_approx(float(sword.damage), 7.0)
		and is_equal_approx(float(sword.attack_range), 64.0)
		and is_equal_approx(float(sword.swing_angle), 90.0),
		"Offline sword consumes the shared Inspector rules")
	check(is_equal_approx(float(guard.maximum), 80.0)
		and is_equal_approx(float(guard.block_cost), 8.0)
		and is_equal_approx(float(guard.duration), 4.0)
		and is_equal_approx(float(guard.recovery_duration), 6.0)
		and is_equal_approx(float(guard.angle), 100.0),
		"Offline guard consumes the same shared Inspector rules")
	actor.free()

func test_real_player_resource_reaches_host() -> void:
	var packed = load("res://scene/maincharac.tscn")
	check(packed is PackedScene, "Real Player scene loads with the shared resource")
	if not packed is PackedScene: return
	var player = packed.instantiate()
	var controller = player.get_node("WeaponController")
	check(controller.combat_rules.resource_path == "res://scene/resources/default_melee_guard_rules.tres",
		"Player Inspector references the reusable default resource")
	controller.combat_rules = custom_rules()
	player.is_locally_controlled = false
	root.add_child(player)
	player.set_physics_process(false)
	var authority = Authority.new()
	check(authority.register_player(&"real", player), "Host reads rules directly from the real Player")
	var guard: Dictionary = authority.get_guard_state(&"real")
	check(is_equal_approx(float(guard.maximum), 80.0)
		and is_equal_approx(float(guard.recovery_duration), 6.0),
		"Real Player Inspector settings reach authoritative guard without a manual override")
	var target = actor_at(Vector2(50, 0))
	authority.register_player(&"target", target)
	authority.submit_command(&"real", {"type": "sword", "direction": Vector2.RIGHT, "action_id": 1}, 1)
	for _tick in range(20): authority.step()
	check(is_equal_approx(float(target.real_hp), 143.0), "Real Player Inspector sword damage and range reach host hits")
	player.free()
	target.free()

func test_authority_uses_host_snapshot_and_ignores_forgery() -> void:
	var rules = custom_rules()
	var config: Dictionary = rules.to_authority_config()
	var authority = Authority.new()
	var attacker = actor_at(Vector2.ZERO)
	var target = actor_at(Vector2(50, 0))
	check(authority.register_player(&"attacker", attacker, {"combat_rules": config}),
		"Host registers a player with a trusted rules snapshot")
	check(authority.register_player(&"target", target), "Target registers with defaults")
	await physics_frame
	var guard: Dictionary = authority.get_guard_state(&"attacker")
	check(is_equal_approx(float(guard.maximum), 80.0)
		and is_equal_approx(float(guard.block_cost), 8.0)
		and is_equal_approx(float(guard.duration), 4.0)
		and is_equal_approx(float(guard.recovery_duration), 6.0)
		and is_equal_approx(float(guard.angle), 100.0),
		"Host guard authority uses the shared snapshot")
	# Editing the Inspector resource after registration cannot mutate the active
	# match; command fields are also untrusted.
	rules.sword_damage = 99.0
	config.sword.damage = 98.0
	check(authority.submit_command(&"attacker", {
		"type": "sword", "direction": Vector2.RIGHT, "action_id": 1,
		"damage": 999.0, "range": 999.0, "arc": 360.0,
	}, 1), "Host accepts a valid sword intent with forged rule fields")
	for _tick in range(20): authority.step()
	check(is_equal_approx(float(target.real_hp), 143.0),
		"Host uses the registered seven-damage snapshot at custom range")
	var hits: Array = authority.get_combat_state().get("melee_events", []).filter(
		func(event: Dictionary) -> bool: return String(event.get("type", "")) == "sword_hit")
	check(hits.size() == 1 and is_equal_approx(float(hits[0].damage), 7.0),
		"Client forgery and later Resource edits cannot change authority damage")
	attacker.free(); target.free()

func test_recovery_limits_attack_and_rules_survive_respawn() -> void:
	var rules = custom_rules()
	rules.sword_cooldown = 0.01
	var authority = Authority.new()
	var actor = actor_at(Vector2.ZERO)
	actor.respawn_delay = 0.05
	authority.register_player(&"player", actor, {"combat_rules": rules.to_authority_config()})
	var command := {"type": "sword", "direction": Vector2.RIGHT, "action_id": 1}
	check(authority.submit_command(&"player", command, 1), "Custom sword begins")
	for _tick in range(20): authority.step()
	command.action_id = 2
	check(not authority.submit_command(&"player", command, 2),
		"Host rejects another swing during recovery even with a shorter cooldown")
	for _tick in range(17): authority.step()
	command.action_id = 3
	check(authority.submit_command(&"player", command, 3), "Host permits a swing after full recovery")
	actor.force_dead()
	for _tick in range(5): authority.step()
	var guard: Dictionary = authority.get_guard_state(&"player")
	check(not actor.is_dead and int(guard.life_id) == 2
		and is_equal_approx(float(guard.value), 80.0)
		and is_equal_approx(float(guard.duration), 4.0)
		and not bool(guard.exhausted), "Respawn restores custom guard rules and full resource")
	actor.free()

func test_long_cooldown_does_not_extend_guard_lock() -> void:
	var rules = custom_rules()
	rules.sword_cooldown = 2.0
	var authority = Authority.new()
	var actor = actor_at(Vector2.ZERO)
	authority.register_player(&"player", actor, {"combat_rules": rules.to_authority_config()})
	authority.submit_command(&"player", {"type": "sword", "direction": Vector2.RIGHT, "action_id": 1}, 1)
	for _tick in range(37): authority.step()
	check(authority.submit_command(&"player", {"type": "guard", "enabled": true, "direction": Vector2.RIGHT}, 2),
		"Guard becomes available when recovery ends even while sword cooldown continues")
	check(bool(authority.get_guard_state(&"player").is_guarding), "Host raises guard after recovery")
	check(not authority.submit_command(&"player", {"type": "sword", "direction": Vector2.RIGHT, "action_id": 2}, 3),
		"Guard availability does not bypass the longer sword cooldown")
	actor.free()
