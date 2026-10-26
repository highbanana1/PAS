extends SceneTree

# Ticket 04 real-Player seam: physical-style input must submit intents through a
# bridge instead of deciding combat/items locally; the replica presenter must
# play each death/respawn transition exactly once; unbind/session close must
# restore the offline authority and input path.
const PLAYER_SCENE := "res://scene/maincharac.tscn"
const Session = preload("res://scene/script/network/network_session.gd")
const Bridge = preload("res://scene/script/network/match_network_bridge.gd")
const HealthData = preload("res://scene/script/items/health_item_data.gd")
const Target = preload("res://tests/fixtures/network_combat_actor.gd")

class FakeBridge extends Node:
	var calls: Array = []
	var world: Array = []
	func submit_fire(direction: Vector2) -> int:
		calls.append({"type": "fire", "direction": direction}); return 1
	func submit_sword(direction: Vector2, action_id: int = -1) -> int:
		calls.append({"type": "sword", "direction": direction, "action_id": action_id}); return 2
	func submit_guard(enabled: bool, direction: Vector2 = Vector2.ZERO) -> int:
		calls.append({"type": "guard", "enabled": enabled, "direction": direction}); return 3
	func submit_pickup(item_id: int, expected_revision: int = -1) -> int:
		calls.append({"type": "pickup", "item_id": item_id, "expected_revision": expected_revision}); return 4
	func submit_use_item(item_id: int, mode: String, expected_revision: int = -1, amount: float = 0.0) -> int:
		calls.append({"type": "use_item", "item_id": item_id, "mode": mode,
			"expected_revision": expected_revision, "amount": amount}); return 5
	func get_world_items() -> Array:
		return world.duplicate(true)
	func count(type: String) -> int:
		return calls.filter(func(call: Dictionary) -> bool: return String(call.get("type", "")) == type).size()
	func last(type: String) -> Dictionary:
		for index in range(calls.size() - 1, -1, -1):
			var call: Dictionary = calls[index]
			if String(call.get("type", "")) == type:
				return call.duplicate(true)
		return {}

var failures: Array[String] = []

func _initialize() -> void:
	run.call_deferred()

func check(ok: bool, label: String) -> void:
	print(("PASS: " if ok else "FAIL: ") + label)
	if not ok:
		failures.append(label)

func action(name: String, pressed: bool = true) -> InputEventAction:
	var event := InputEventAction.new()
	event.action = name
	event.pressed = pressed
	return event

func player_at(position: Vector2) -> Node2D:
	var packed: Resource = load(PLAYER_SCENE)
	if packed == null or not packed.has_method("instantiate"):
		check(false, "Real player scene loads")
		return null
	var player: Node2D = packed.instantiate()
	if player == null:
		check(false, "Real player scene instantiates")
		return null
	player.global_position = position
	player.spawn_position = position
	root.add_child(player)
	return player

func release_all() -> void:
	for name in ["fire", "block", "item_use", "item_pickup",
			"item_select_1", "item_select_2", "item_select_3"]:
		Input.action_release(name)

func run() -> void:
	await test_real_input_submits_intents_only()
	await test_replica_presenter_dedupes_lifecycle()
	await test_unbind_and_session_close_restore_offline()
	release_all()
	print("RESULT: ", failures.size(), " failures")
	quit(0 if failures.is_empty() else 1)

func test_real_input_submits_intents_only() -> void:
	release_all()
	var bridge := FakeBridge.new()
	root.add_child(bridge)
	var player := player_at(Vector2.ZERO)
	if player == null: return
	await process_frame
	player.set_physics_process(false)
	player.get_weapon_controller().set_process(false)
	var item_input = player.get_node("LocalItemInput")
	item_input.set_process(false)
	var combat_input = player.get_weapon_controller().get_node("LocalCombatInput")
	player.set_network_authority(true)
	check(player.bind_network_intents(bridge, &"local-player"), "Real player binds network input intents")
	check(combat_input.uses_network_intents() and item_input.uses_network_intents(),
		"Both real input adapters are bound to the bridge")

	var target := Target.new()
	target.position = Vector2(24, 0)
	root.add_child(target)
	await process_frame
	var target_health: float = target.real_hp
	player.get_weapon_controller().equip_weapon(0)
	Input.action_press("fire")
	combat_input.tick(1.0 / 60.0)
	Input.action_release("fire")
	combat_input.tick(1.0 / 60.0)
	check(bridge.count("fire") == 1, "Real fire key submits one fire intent")
	check(is_equal_approx(target.real_hp, target_health), "Fire intent does not damage locally")
	check(is_zero_approx(player.get_node("gun").get_shot_cycle().remaining),
		"Fire intent does not start the local gun cycle")

	player.get_weapon_controller().equip_weapon(1)
	Input.action_press("fire")
	combat_input.tick(1.0 / 60.0)
	Input.action_release("fire")
	combat_input.tick(1.0 / 60.0)
	check(bridge.count("sword") == 1, "Real fire key submits a sword intent while the sword is equipped")
	check(is_equal_approx(target.real_hp, target_health), "Sword intent does not damage locally")

	Input.action_press("block")
	combat_input.tick(1.0 / 60.0)
	var guard_on: Dictionary = bridge.last("guard")
	Input.action_release("block")
	combat_input.tick(1.0 / 60.0)
	var guard_off: Dictionary = bridge.last("guard")
	check(bool(guard_on.get("enabled", false)), "Holding block submits guard on")
	check(not bool(guard_off.get("enabled", true)), "Releasing block submits guard off")
	check(not player.get_weapon_controller().is_guarding, "Input intent does not raise local guard")
	# Holding block while attacking must not queue a guard command that the host
	# rejects during sword recovery and the client then mistakes as accepted.
	player.get_weapon_controller().equip_weapon(1)
	Input.action_press("block")
	combat_input.tick(1.0 / 60.0)
	var guard_calls_before_attack := bridge.count("guard")
	Input.action_press("fire")
	combat_input.tick(1.0 / 60.0)
	Input.action_release("fire")
	combat_input.tick(1.0 / 60.0)
	check(bridge.count("guard") == guard_calls_before_attack,
		"Held block does not resubmit during authoritative sword recovery")
	Input.action_release("block")
	combat_input.tick(1.0 / 60.0)

	bridge.world = [{"item_id": 7, "revision": 4, "state": "world",
		"type": "health", "remaining": 30.0, "capacity": 30.0, "owner": "",
		"position": {"x": 8.0, "y": 0.0}}]
	check(item_input.handle_event(action("item_pickup")), "Pickup key is handled in network mode")
	var pickup: Dictionary = bridge.last("pickup")
	check(int(pickup.get("item_id", 0)) == 7 and int(pickup.get("expected_revision", 0)) == 4,
		"Pickup intent carries item id and observed revision")
	check(player.get_inventory_component().items.is_empty(), "Pickup intent does not add a local item")

	player.apply_authoritative_items([{"item_id": 9, "type": "health", "remaining": 30.0,
		"capacity": 30.0, "owner": "local-player", "revision": 5, "state": "carried",
		"position": {"x": 0.0, "y": 0.0}}])
	item_input.handle_event(action("item_select_1"))
	item_input.handle_event(action("item_use"))
	var expand: Dictionary = bridge.last("use_item")
	check(int(expand.get("item_id", 0)) == 9 and String(expand.get("mode", "")) == "expand"
		and int(expand.get("expected_revision", 0)) == 5, "E submits expansion with id/revision")
	check(player.get_inventory_component().items.size() == 1
		and is_equal_approx(float(player.get_inventory_component().items[0].remaining), 30.0),
		"E intent does not consume the local replica item")

	player.apply_authoritative_items([{"item_id": 10, "type": "jump", "remaining": 2.0,
		"capacity": 2.0, "owner": "local-player", "revision": 2, "state": "carried",
		"position": {"x": 0.0, "y": 0.0}}])
	item_input.handle_event(action("item_select_1"))
	item_input.handle_event(action("item_use"))
	var jump_use: Dictionary = bridge.last("use_item")
	check(int(jump_use.get("item_id", 0)) == 10 and String(jump_use.get("mode", "")) == "jump"
		and int(jump_use.get("expected_revision", 0)) == 2, "E submits the jump use intent")
	check(player.get_motor().extra_air_jumps == 0 and player.get_inventory_component().items.size() == 1,
		"Jump intent does not grant or consume locally")
	check(is_equal_approx(float(player.get_inventory_component().items[0].capacity), 2.0)
		and is_equal_approx(float(player.get_inventory_component().items[0].remaining), 2.0),
		"Jump item replica preserves authoritative capacity and reserve")

	player.apply_authoritative_items([{"item_id": 11, "type": "health", "remaining": 30.0,
		"capacity": 30.0, "owner": "local-player", "revision": 7, "state": "carried",
		"position": {"x": 0.0, "y": 0.0}}])
	item_input.handle_event(action("item_select_1"))
	item_input.tick(0.35)
	item_input.tick(0.25)
	var heal: Dictionary = bridge.last("use_item")
	check(int(heal.get("item_id", 0)) == 11 and String(heal.get("mode", "")) == "heal"
		and int(heal.get("expected_revision", 0)) == 7 and float(heal.get("amount", 0.0)) > 0.0,
		"Holding the selected health slot submits a host heal chunk")

	# Offline branch is preserved exactly: after clearing the bridge the same
	# adapters consume and expand the local inventory again.
	player.clear_network_intents()
	player.set_network_authority(false)
	check(not combat_input.uses_network_intents() and combat_input.enabled(),
		"Unbound real player returns to the offline combat input path")
	var calls_before := bridge.calls.size()
	var inventory = player.get_inventory_component()
	inventory.add_item(HealthData.new(30))
	var max_before: float = player.max_hp
	item_input.handle_event(action("item_select_2"))
	item_input.handle_event(action("item_use"))
	check(is_equal_approx(player.max_hp, max_before + player.health_per_cell),
		"Offline E still expands one local health cell")
	check(bridge.calls.size() == calls_before, "Offline item use never reaches the face bridge")
	player.free()
	target.free()
	bridge.free()
	await process_frame

func test_replica_presenter_dedupes_lifecycle() -> void:
	var player := player_at(Vector2.ZERO)
	if player == null: return
	await process_frame
	player.set_physics_process(false)
	player.get_weapon_controller().set_process(false)
	player.get_node("LocalItemInput").set_process(false)
	player.set_network_authority(true)
	player.apply_authoritative_items([{"item_id": 21, "type": "health", "remaining": 30.0,
		"capacity": 30.0, "owner": "local-player", "revision": 1, "state": "carried",
		"position": {"x": 0.0, "y": 0.0}}])
	var deaths := [0]
	var respawns := [0]
	player.character_died.connect(func() -> void: deaths[0] += 1)
	player.respawned.connect(func() -> void: respawns[0] += 1)
	var drops_before := get_nodes_in_group("health_item_pickup").size()

	check(player.apply_replica_state({"life_id": 1, "dead": false, "health": 150.0,
		"max_health": 150.0, "position": Vector2(10, 0), "velocity": Vector2.ZERO}),
		"Replica accepts the first authoritative live state")
	check(deaths[0] == 0 and respawns[0] == 0, "Initial live state plays no lifecycle transition")
	check(player.apply_replica_state({"life_id": 1, "dead": true, "health": 0.0,
		"max_health": 150.0, "position": Vector2(10, 0), "respawn_remaining": 4.0}),
		"Replica accepts an authoritative death state")
	check(deaths[0] == 1 and player.is_dead and is_zero_approx(player.real_hp),
		"Death presentation plays once and converges to dead/zero health")
	check(get_nodes_in_group("health_item_pickup").size() == drops_before,
		"Replica death never creates local dropped items")
	check(player.get_inventory_component().items.size() == 1,
		"Replica death never decides local inventory loss")
	player.apply_replica_state({"life_id": 1, "dead": true, "health": 0.0,
		"max_health": 150.0, "position": Vector2(10, 0)})
	player.apply_replica_state({"life_id": 1, "dead": true, "health": 0.0,
		"max_health": 150.0, "position": Vector2(10, 0)})
	check(deaths[0] == 1, "Duplicate death states never replay the death presentation")

	player.apply_replica_state({"life_id": 2, "dead": false, "health": 150.0,
		"max_health": 150.0, "position": Vector2(32, 0), "velocity": Vector2.ZERO,
		"respawn_remaining": 0.0})
	check(respawns[0] == 1 and not player.is_dead and is_equal_approx(player.real_hp, 150.0),
		"Respawn presentation plays once and converges to the new life")
	check(player.global_position == Vector2(32, 0), "Respawn presentation converges to the authoritative position")
	# A delayed old-life death must not roll the presenter back.
	var ignored: bool = player.apply_replica_state({"life_id": 1, "dead": true, "health": 0.0,
		"max_health": 150.0, "position": Vector2(10, 0)})
	check(not ignored and deaths[0] == 1 and respawns[0] == 1 and not player.is_dead,
		"Old-life death is ignored for presentation")
	check(player.global_position == Vector2(32, 0) and is_equal_approx(player.real_hp, 150.0),
		"Old-life state cannot regress replica position or health")
	player.apply_replica_state({"life_id": 2, "dead": false, "health": 150.0,
		"max_health": 150.0, "position": Vector2(32, 0)})
	check(respawns[0] == 1, "Duplicate live state never replays the respawn presentation")
	player.apply_replica_state({"life_id": 2, "dead": true, "health": 0.0,
		"max_health": 150.0, "position": Vector2(32, 0)})
	player.apply_replica_state({"life_id": 3, "dead": false, "health": 150.0,
		"max_health": 150.0, "position": Vector2(64, 0)})
	var counts: Dictionary = player.get_replica_presentation_counts()
	check(deaths[0] == 2 and respawns[0] == 2, "Each distinct life transition plays exactly once")
	check(int(counts.get("death", 0)) == 2 and int(counts.get("respawn", 0)) == 2,
		"Presenter counters match the emitted lifecycle signals")
	check(get_nodes_in_group("health_item_pickup").size() == drops_before,
		"Full death/respawn sequence creates no local drops")
	player.free()
	await process_frame

func test_unbind_and_session_close_restore_offline() -> void:
	var session = Session.new()
	session.name = "RestoreSession"
	root.add_child(session)
	check(session.host(0, {"match_epoch": 424242}) == OK, "Restore fixture starts a real host session")
	var bridge = Bridge.new()
	bridge.name = "RestoreBridge"
	root.add_child(bridge)
	check(bridge.configure(session), "Restore bridge configures on the host")
	var player := player_at(Vector2.ZERO)
	if player == null: return
	await process_frame
	player.set_physics_process(false)
	player.get_weapon_controller().set_process(false)
	var player_id: StringName = StringName(String(session.get_local_identity().get("player_id", "")))
	check(bridge.bind_actor(player_id, player, true), "Host binds its real local player")
	check(player.network_authority and player.authority_controlled,
		"Bound player uses network authority and authority-driven movement")
	check(player.network_simulation_authority,
		"Host-bound real player keeps host-side contact simulation authority")
	var contact_health_before: float = player.real_hp
	player.queue_contact_damage(15.0, player.global_position + Vector2.LEFT)
	player.hit_cooldown(1.0 / 60.0)
	check(player.real_hp < contact_health_before,
		"Host network actor still applies authoritative contact damage")
	check(player.get_weapon_controller().network_authority,
		"Bound weapon controller suspends local combat decisions")
	var combat_input = player.get_weapon_controller().get_node("LocalCombatInput")
	var item_input = player.get_node("LocalItemInput")
	check(combat_input.uses_network_intents() and item_input.uses_network_intents(),
		"Bound local player has both intent adapters armed")

	check(bridge.unbind_actor(player), "Explicit unbind succeeds")
	check(not player.network_authority and not player.authority_controlled,
		"Unbind restores offline authority immediately")
	check(not player.get_weapon_controller().network_authority,
		"Unbind restores local weapon adjudication")
	check(not combat_input.uses_network_intents() and not item_input.uses_network_intents(),
		"Unbind clears both network intent adapters")
	check(combat_input.enabled() and item_input.enabled(), "Unbound local input adapters are usable offline")
	check(bridge.get_authority().get_snapshot(player_id).is_empty(),
		"Unbind removes the actor from the host authority")
	check(player.get_node("LocalItemInput").is_processing(), "Item input processing remains enabled offline")

	check(bridge.bind_actor(player_id, player, true), "The same local player can bind again")
	check(player.network_authority and combat_input.uses_network_intents(),
		"Rebound player returns to the network intent path")
	session.stop()
	await process_frame
	check(not player.network_authority and not player.authority_controlled,
		"Session close restores offline authority for every bound actor")
	check(not player.get_weapon_controller().network_authority,
		"Session close restores local weapon adjudication")
	check(not combat_input.uses_network_intents() and not item_input.uses_network_intents(),
		"Session close clears both intent adapters")
	check(combat_input.enabled() and item_input.enabled(),
		"Session close leaves local input ready for offline play")
	check(bridge.get_bound_actor(player_id) == null,
		"Session close unbinds the bridge actor table")
	check(bridge.get_authority().get_snapshot(player_id).is_empty(),
		"Session close unregisters the host authority player")
	player.free()
	bridge.free()
	session.free()
	await process_frame
