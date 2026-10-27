extends SceneTree

# Ticket 04 authority seam: sword action identity/life idempotency, host-owned
# guard, authoritative shotgun blocking, authority-clocked death/respawn and
# stable item ownership. These tests only use the MatchAuthority public API.
const Authority = preload("res://scene/script/network/match_authority.gd")
const Actor = preload("res://tests/fixtures/network_combat_actor.gd")
const Context = preload("res://scene/script/combat/attack_context.gd")
const CombatReplica = preload("res://scene/script/network/combat_replica.gd")

var failures: Array[String] = []

func _initialize() -> void:
	run.call_deferred()

func check(ok: bool, label: String) -> void:
	print(("PASS: " if ok else "FAIL: ") + label)
	if not ok:
		failures.append(label)

func actor_at(position: Vector2):
	var actor = Actor.new()
	actor.position = position
	root.add_child(actor)
	return actor

func sword(direction: Vector2, action_id: int, extra: Dictionary = {}) -> Dictionary:
	var command := {"type": "sword", "direction": direction, "action_id": action_id}
	command.merge(extra)
	return command

func guard(enabled: bool, direction: Vector2 = Vector2.ZERO) -> Dictionary:
	return {"type": "guard", "enabled": enabled, "direction": direction}

func events_of(state: Dictionary, type: String, key: String = "events") -> Array:
	var result: Array = []
	for event in state.get(key, []):
		if event is Dictionary and String(event.get("type", "")) == type:
			result.append(event)
	return result

func melee_events(state: Dictionary, type: String) -> Array:
	return events_of(state, type, "melee_events")

func step_ticks(authority, count: int) -> void:
	for index in range(count):
		authority.step()

func run() -> void:
	await test_sword_validation_identity_and_dedupe()
	await test_sword_incremental_sweep()
	await test_sword_range_arc_and_wall()
	await test_guard_direction_and_block_cost()
	await test_guard_exhaustion_lock_and_recovery()
	await test_attack_cancels_guard()
	await test_shotgun_uses_authoritative_guard()
	await test_death_respawn_and_life_rollover()
	await test_items_checkpoint_drop_and_pickup_race()
	await test_item_use_two_health_modes_and_jump_replay()
	await test_item_slots_world_state_and_revision_cas()
	await test_weapon_damage_ignores_contact_invincibility_fields()
	print("RESULT: ", failures.size(), " failures")
	quit(0 if failures.is_empty() else 1)

func test_sword_validation_identity_and_dedupe() -> void:
	var a = Authority.new()
	var attacker = actor_at(Vector2.ZERO)
	var target = actor_at(Vector2(24, 0))
	a.register_player(&"attacker", attacker)
	a.register_player(&"target", target)
	await physics_frame
	check(not a.submit_command(&"unknown", sword(Vector2.RIGHT, 1), 1), "Sword rejects an unregistered attacker")
	for direction in [Vector2.ZERO, Vector2(NAN, 0), Vector2(INF, 0), Vector2(1e30, 0)]:
		check(not a.submit_command(&"attacker", sword(direction, 2), 2), "Sword rejects an invalid aim: " + str(direction))
	check(not a.submit_command(&"attacker", {"type": "sword", "direction": "right", "action_id": 2}, 2), "Sword rejects a non-vector aim")
	check(not a.submit_command(&"attacker", {"type": "sword", "direction": Vector2.RIGHT}, 3), "Sword requires a stable action id")
	# Forged target/damage/life claims are ignored; host derives both identities.
	var forged := sword(Vector2.RIGHT, 10, {"target_id": "attacker", "target_life_id": 99, "damage": 9999, "attacker_id": "target"})
	check(a.submit_command(&"attacker", forged, 4), "A valid sword swing is accepted despite forged claims")
	check(not a.submit_command(&"attacker", sword(Vector2.RIGHT, 10), 5), "Duplicate action id is rejected before resolution")
	step_ticks(a, 4)
	check(target.real_hp == 148.0, "Sword deals the existing two damage once")
	check(attacker.real_hp == 150.0, "Forged target identity cannot damage the attacker")
	var hits := melee_events(a.get_combat_state(), "sword_hit")
	check(hits.size() == 1, "One accepted action emits one sword hit")
	if not hits.is_empty():
		check(String(hits[0].get("attacker_id", "")) == "attacker", "Host derives the attacker identity")
		check(String(hits[0].get("target_id", "")) == "target", "Host derives the target identity")
		check(int(hits[0].get("target_life_id", 0)) == 1, "Hit carries the target life id")
	check(not a.submit_command(&"attacker", sword(Vector2.RIGHT, 10), 6), "Delayed duplicate action id is still rejected")
	step_ticks(a, 4)
	check(target.real_hp == 148.0, "Delayed duplicate cannot damage the same life twice")
	check(not a.submit_command(&"attacker", sword(Vector2.RIGHT, 11), 7), "Cooldown rejects a new sword action immediately")
	step_ticks(a, 16)
	check(a.submit_command(&"attacker", sword(Vector2.RIGHT, 12), 8), "Sword is accepted again after authoritative cooldown")
	step_ticks(a, 4)
	check(target.real_hp == 146.0, "Second legal action damages once")
	attacker.force_dead()
	check(not a.submit_command(&"attacker", sword(Vector2.RIGHT, 13), 9), "Dead attacker cannot swing")
	attacker.free()
	target.free()

func test_sword_incremental_sweep() -> void:
	var a = Authority.new()
	var attacker = actor_at(Vector2.ZERO)
	# Forty-five degrees to the blade's positive side: outside the first sectors.
	var side = actor_at(Vector2(18, 18))
	a.register_player(&"attacker", attacker)
	a.register_player(&"side", side)
	await physics_frame
	check(a.submit_command(&"attacker", sword(Vector2.RIGHT, 90), 1), "Incremental sweep fixture is accepted")
	step_ticks(a, 3)
	check(side.real_hp == 150.0, "Sword does not hit a not-yet-swept side target on the first sector")
	step_ticks(a, 2)
	check(side.real_hp == 150.0, "Side target waits until the blade reaches its sector")
	step_ticks(a, 1)
	check(side.real_hp == 148.0, "Sweep hits a target in a later angular sector")
	step_ticks(a, 4)
	check(side.real_hp == 148.0, "A later sector cannot hit the same target life twice")
	check(melee_events(a.get_combat_state(), "sword_hit").size() == 1, "One swept target life emits exactly one hit")
	attacker.free(); side.free()

	var b = Authority.new()
	var late_attacker = actor_at(Vector2.ZERO)
	var late = actor_at(Vector2(-80, 0))
	b.register_player(&"attacker", late_attacker)
	b.register_player(&"late", late)
	await physics_frame
	check(b.submit_command(&"attacker", sword(Vector2.RIGHT, 91), 1), "Late-entry sweep fixture is accepted")
	step_ticks(b, 4)
	check(late.real_hp == 150.0, "Out-of-range target is not hit by the early sweep")
	late.global_position = Vector2(18, 18)
	await physics_frame
	step_ticks(b, 2)
	check(late.real_hp == 148.0, "A target entering a later swept sector can be hit")
	late_attacker.free(); late.free()

	var c = Authority.new()
	var doomed_attacker = actor_at(Vector2.ZERO)
	var target = actor_at(Vector2(24, 0))
	c.register_player(&"attacker", doomed_attacker)
	c.register_player(&"target", target)
	await physics_frame
	check(c.submit_command(&"attacker", sword(Vector2.RIGHT, 92), 1), "Mid-sweep cancellation fixture is accepted")
	step_ticks(c, 3)
	doomed_attacker.force_dead()
	step_ticks(c, 1)
	check(target.real_hp == 150.0, "An old-life sweep cancels before its later sectors resolve")
	var state: Dictionary = c.get_combat_state()
	check(melee_events(state, "sword_reset").size() == 1, "Old-life sweep is cancelled by the authority life reset")
	check(int(state.get("pending_swords", -1)) == 0, "Cancelled old-life action is removed from the sweep queue")
	doomed_attacker.free(); target.free()

func test_sword_range_arc_and_wall() -> void:
	var a = Authority.new()
	var attacker = actor_at(Vector2.ZERO)
	var near = actor_at(Vector2(24, 0))
	var behind = actor_at(Vector2(-24, 0))
	var outside_arc = actor_at(Vector2(10, -30))
	var distant = actor_at(Vector2(80, 0))
	a.register_player(&"attacker", attacker)
	a.register_player(&"near", near)
	a.register_player(&"behind", behind)
	a.register_player(&"outside_arc", outside_arc)
	a.register_player(&"distant", distant)
	await physics_frame
	check(a.submit_command(&"attacker", sword(Vector2.RIGHT, 20), 1), "Range/arc fixture swing is accepted")
	step_ticks(a, 4)
	check(near.real_hp == 148.0, "Sword hits a target inside range and the front arc")
	check(behind.real_hp == 150.0, "Sword ignores a target behind the arc")
	check(outside_arc.real_hp == 150.0, "Sword ignores a target outside the 120 degree arc")
	check(distant.real_hp == 150.0, "Sword ignores a target beyond 36 units")
	attacker.free(); near.free(); behind.free(); outside_arc.free(); distant.free()

	var b = Authority.new()
	var walled_attacker = actor_at(Vector2.ZERO)
	var walled_target = actor_at(Vector2(24, 0))
	var wall := StaticBody2D.new()
	wall.position = Vector2(12, 0)
	wall.collision_layer = 1
	var shape := CollisionShape2D.new()
	var rectangle := RectangleShape2D.new()
	rectangle.size = Vector2(2, 80)
	shape.shape = rectangle
	wall.add_child(shape)
	root.add_child(wall)
	b.register_player(&"attacker", walled_attacker)
	b.register_player(&"target", walled_target)
	await physics_frame
	b.submit_command(&"attacker", sword(Vector2.RIGHT, 30), 1)
	step_ticks(b, 4)
	check(walled_target.real_hp == 150.0, "Sword cannot hit through world geometry")
	walled_attacker.free(); walled_target.free(); wall.free()

func test_guard_direction_and_block_cost() -> void:
	var a = Authority.new()
	var attacker = actor_at(Vector2.ZERO)
	var target = actor_at(Vector2(24, 0))
	a.register_player(&"attacker", attacker)
	a.register_player(&"target", target)
	await physics_frame
	check(a.submit_command(&"target", guard(true, Vector2.LEFT), 1), "Guard command is accepted with a host-validated direction")
	var state: Dictionary = a.get_guard_state(&"target")
	check(bool(state.get("is_guarding", false)), "Guard state is active immediately")
	check(a.submit_command(&"attacker", sword(Vector2.RIGHT, 40), 2), "Attacker swings into a raised guard")
	step_ticks(a, 4)
	check(target.real_hp == 150.0, "Frontal melee is blocked without health damage")
	var after: Dictionary = a.get_guard_state(&"target")
	check(absf(float(after.get("value", 0.0)) - 79.5) < 1.0, "Successful block spends the existing twenty guard points")
	var hits := melee_events(a.get_combat_state(), "sword_hit")
	check(hits.size() == 1 and int(hits[0].get("result", -1)) == Context.Result.BLOCKED, "Blocked hit reports the existing BLOCKED result")
	check(not hits.is_empty() and int(hits[0].get("target_life_id", 0)) == 1, "Blocked hit still carries the target life id")

	# Wrong facing direction does not block.
	check(a.submit_command(&"target", guard(true, Vector2.RIGHT), 3), "Guard direction can be changed")
	step_ticks(a, 16)
	check(a.submit_command(&"attacker", sword(Vector2.RIGHT, 41), 4), "Second swing is accepted after cooldown")
	step_ticks(a, 4)
	check(target.real_hp == 148.0, "Attack from outside the allowed guard arc deals damage")
	check(bool(a.get_guard_state(&"target").get("is_guarding", false)), "Guard remains raised but does not absorb a rear attack")
	attacker.free(); target.free()

func test_guard_exhaustion_lock_and_recovery() -> void:
	var a = Authority.new()
	var player = actor_at(Vector2.ZERO)
	a.register_player(&"player", player)
	await physics_frame
	check(a.submit_command(&"player", guard(true, Vector2.RIGHT), 1), "Guard starts")
	var drain_revision_before := int(a.get_combat_state().get("revision", -1))
	step_ticks(a, 3)
	check(int(a.get_combat_state().get("revision", -1)) > drain_revision_before,
		"Continuous guard drain advances the published combat checkpoint")
	step_ticks(a, 597)
	var state: Dictionary = a.get_guard_state(&"player")
	check(float(state.get("value", -1.0)) == 0.0 and bool(state.get("exhausted", false)), "Ten seconds of guarding empties the meter and exhausts the player")
	check(not bool(state.get("is_guarding", true)), "Exhaustion lowers the guard")
	check(a.submit_command(&"player", guard(true, Vector2.RIGHT), 2), "A guard request during exhaustion is accepted as intent")
	step_ticks(a, 1)
	check(not bool(a.get_guard_state(&"player").get("is_guarding", true)), "Exhausted guard cannot restart before full recovery")
	step_ticks(a, 449)
	state = a.get_guard_state(&"player")
	check(float(state.get("value", 0.0)) > 40.0 and not bool(state.get("is_guarding", true)), "Half recovery does not unlock guarding")
	step_ticks(a, 450)
	state = a.get_guard_state(&"player")
	check(float(state.get("value", 0.0)) == 100.0 and not bool(state.get("exhausted", true)), "Fifteen seconds of recovery restores the full meter")
	check(a.submit_command(&"player", guard(true, Vector2.RIGHT), 3), "Fresh guard request after full recovery")
	step_ticks(a, 1)
	check(bool(a.get_guard_state(&"player").get("is_guarding", false)), "Guard unlocks only after the meter is completely full")
	player.free()

func test_attack_cancels_guard() -> void:
	var a = Authority.new()
	var player = actor_at(Vector2.ZERO)
	var dummy = actor_at(Vector2(24, 0))
	a.register_player(&"player", player)
	a.register_player(&"dummy", dummy)
	await physics_frame
	check(a.submit_command(&"player", guard(true, Vector2.RIGHT), 1), "Guard is raised before attacking")
	check(a.submit_command(&"player", sword(Vector2.RIGHT, 50), 2), "Sword command is accepted while guarding")
	check(not bool(a.get_guard_state(&"player").get("is_guarding", true)), "Attack immediately cancels guard")
	check(not bool(a.get_guard_state(&"player").get("hold_requested", true)), "Attack clears the held guard request")
	check(not a.submit_command(&"player", guard(true, Vector2.RIGHT), 3), "Held guard cannot interrupt an active swing")
	step_ticks(a, 16)
	check(not bool(a.get_guard_state(&"player").get("is_guarding", true)), "Guard does not silently resume during the swing")
	check(a.submit_command(&"player", guard(true, Vector2.RIGHT), 4), "Guard can be requested again after the swing window")
	step_ticks(a, 1)
	check(bool(a.get_guard_state(&"player").get("is_guarding", false)), "New guard request raises guard after recovery")
	player.free(); dummy.free()

func test_shotgun_uses_authoritative_guard() -> void:
	var a = Authority.new()
	var shooter = actor_at(Vector2.ZERO)
	var target = actor_at(Vector2(48, 0))
	a.register_player(&"shooter", shooter)
	a.register_player(&"target", target)
	await physics_frame
	check(a.submit_command(&"target", guard(true, Vector2.LEFT), 1), "Target raises guard toward the shotgun")
	check(a.submit_command(&"shooter", {"type": "fire", "direction": Vector2.RIGHT, "guard_value": 100, "target_guard": 0}, 2), "Shotgun fire is accepted despite forged guard claims")
	step_ticks(a, 8)
	check(target.real_hp == 150.0, "Authoritative shotgun pellets are blocked by the host-owned guard")
	var state: Dictionary = a.get_guard_state(&"target")
	check(bool(state.get("exhausted", false)) and float(state.get("value", -1.0)) < 1.0, "Five blocked pellets spend five twenty-point blocks and exhaust guard")
	var blocked_events := events_of(a.get_combat_state(), "guard_blocked")
	check(blocked_events.size() == 5, "Each authoritative pellet makes its own guard decision")
	# Wrong direction: the same shot must damage. Free the first pair so the new
	# actors do not overlap the old collision bodies.
	shooter.free(); target.free()
	var b = Authority.new()
	var shooter2 = actor_at(Vector2(200, 0))
	var target2 = actor_at(Vector2(248, 0))
	b.register_player(&"shooter", shooter2)
	b.register_player(&"target", target2)
	await physics_frame
	b.submit_command(&"target", guard(true, Vector2.RIGHT), 1)
	b.submit_command(&"shooter", {"type": "fire", "direction": Vector2.RIGHT}, 2)
	step_ticks(b, 8)
	check(target2.real_hp == 140.0, "Shotgun pellets damage a target guarding the wrong way")
	check(float(b.get_guard_state(&"target").get("value", 0.0)) > 95.0, "Rear attacks do not spend guard")
	shooter2.free(); target2.free()

func test_death_respawn_and_life_rollover() -> void:
	var a = Authority.new()
	var attacker = actor_at(Vector2.ZERO)
	var target = actor_at(Vector2(24, 0))
	target.respawn_delay = 5.0
	a.register_player(&"attacker", attacker)
	a.register_player(&"target", target)
	await physics_frame
	var item_id: int = a.grant_item(&"target", "health", 30.0, 30.0)
	check(item_id > 0, "Host grants a stable backpack item id")
	check(a.submit_command(&"target", guard(true, Vector2.RIGHT), 1), "Target guards the wrong way before dying")
	target.health_component.set_current(2.0)
	check(a.submit_command(&"attacker", sword(Vector2.RIGHT, 60), 2), "Lethal sword is accepted against the exposed side")
	step_ticks(a, 5)
	check(target.is_dead and target.real_hp == 0.0, "Sword death depletes the target")
	var lifecycle_events: Array = a.drain_events()
	var saw_death := false
	var death_life := -1
	for event in lifecycle_events:
		if String(event.get("type", "")) == "player_died":
			saw_death = true
			death_life = int(event.get("life_id", -1))
	check(saw_death, "Authority emits exactly one player_died event")
	check(death_life == 1, "Death event carries the dying life id")
	var items: Dictionary = a.get_item_state()
	check(String(items.get("items", {}).get(str(item_id), {}).get("owner", "target")) == "", "Death clears item ownership")
	check(not bool(a.get_guard_state(&"target").get("is_guarding", true)), "Death lowers guard")
	# The world keeps running: another player moves while the target is dead.
	attacker.set_physics_process(true)
	var before: Vector2 = attacker.global_position
	a.submit_command(&"attacker", {"type": "move", "direction": Vector2.RIGHT})
	step_ticks(a, 30)
	check(attacker.global_position.x > before.x + 1.0, "Other players keep moving while one player is dead")
	# Extra dead ticks must not duplicate the drop.
	step_ticks(a, 60)
	check(a.get_item_state().get("items", {}).size() == 1, "Repeated dead ticks do not duplicate the death drop")
	check(String(a.get_item_state().get("items", {}).get(str(item_id), {}).get("owner", "target")) == "", "One death drop keeps the item unowned exactly once")
	# Finish the five-second authority clock from the actual death tick.
	var respawned := false
	var respawn_life := -1
	for index in range(320):
		a.step()
		for event in a.drain_events():
			if String(event.get("type", "")) == "player_respawned":
				respawned = true
				respawn_life = int(event.get("life_id", -1))
				break
		if respawned:
			break
	check(respawned, "Five-second authority clock respawns the target")
	check(respawn_life == 2, "Respawn advances the stable target life id")
	check(not target.is_dead and target.real_hp == 150.0, "Respawn restores five health cells")
	var snapshot: Dictionary = a.get_snapshot(&"target")
	check(int(snapshot.get("life_id", 0)) == 2, "Snapshot carries the new target life id")
	var guard_state: Dictionary = a.get_guard_state(&"target")
	check(float(guard_state.get("value", 0.0)) == 100.0 and not bool(guard_state.get("exhausted", true)), "Respawn resets guard to full and clears exhaustion")
	check(not bool(guard_state.get("is_guarding", true)) and not bool(guard_state.get("hold_requested", true)), "Respawn clears guard state and held input")
	check(target.velocity == Vector2.ZERO and target.get_motor().jump_count == 1, "Respawn resets movement and jump state")
	# A delayed action id from the old life remains idempotent after the life rollover.
	var hp_before: float = target.real_hp
	check(not a.submit_command(&"attacker", sword(Vector2.RIGHT, 60), 9), "Old action id cannot be replayed against the new life")
	step_ticks(a, 4)
	check(target.real_hp == hp_before, "Delayed old-life action cannot damage the respawned life")
	attacker.free(); target.free()

func test_items_checkpoint_drop_and_pickup_race() -> void:
	var a = Authority.new()
	var first = actor_at(Vector2.ZERO)
	var second = actor_at(Vector2(24, 0))
	var dying = actor_at(Vector2(12, 0))
	a.register_player(&"first", first)
	a.register_player(&"second", second)
	a.register_player(&"dying", dying)
	await physics_frame
	var health_id: int = a.grant_item(&"dying", "health", 12.0, 30.0)
	var jump_id: int = a.grant_item(&"dying", "jump", 1.0, 1.0)
	var checkpoint: Dictionary = a.get_item_state()
	var health: Dictionary = checkpoint.get("items", {}).get(str(health_id), {})
	check(String(health.get("type", "")) == "health" and is_equal_approx(float(health.get("remaining", 0.0)), 12.0), "Item checkpoint keeps the existing health reserve")
	check(String(health.get("owner", "")) == "dying" and int(health.get("revision", 0)) >= 1, "Item checkpoint carries owner and revision")
	var jump: Dictionary = checkpoint.get("items", {}).get(str(jump_id), {})
	check(String(jump.get("type", "")) == "jump" and is_equal_approx(float(jump.get("remaining", 0.0)), 1.0), "Item checkpoint keeps the one-shot jump state")
	for key in ["item_id", "type", "remaining", "capacity", "owner", "revision"]:
		check(health.has(key), "Item network state includes only stable field: " + key)
	for forbidden in ["node", "resource", "weakref", "texture", "rid", "instance_id", "icon", "holder"]:
		check(not health.has(forbidden), "Item network state omits forbidden field: " + forbidden)
	var encoded := JSON.stringify(checkpoint)
	check(encoded.length() > 0 and not encoded.contains("Object"), "Item checkpoint is plain JSON-serializable data")
	# Death drops both items exactly once.
	dying.health_component.set_current(2.0)
	a.submit_command(&"second", sword(Vector2.LEFT, 70), 1)
	# second at 24 swings left at dying at 12 (distance 12) for lethal two damage.
	step_ticks(a, 4)
	check(dying.is_dead, "Pickup-race fixture kills the item owner")
	step_ticks(a, 8)
	check(a.get_item_state().get("items", {}).size() == 2, "Death drop cannot create duplicate item records")
	check(String(a.get_item_state().get("items", {}).get(str(health_id), {}).get("owner", "x")) == "", "Dropped item is unowned")
	# First host-ordered request wins; the later competing request reuses the
	# same observed revision and is rejected by the host CAS.
	var observed_revision := int(a.get_item_state().items[str(health_id)].revision)
	check(a.submit_command(&"first", {"type": "pickup", "item_id": health_id,
		"expected_revision": observed_revision, "owner": "second"}, 2), "First pickup request wins on the host")
	check(not a.submit_command(&"second", {"type": "pickup", "item_id": health_id,
		"expected_revision": observed_revision}, 3), "Competing pickup request loses the revision race")
	check(not a.submit_command(&"second", {"type": "pickup", "item_id": health_id,
		"expected_revision": observed_revision + 1}, 4), "Duplicate pickup request cannot transfer ownership")
	var final: Dictionary = a.get_item_state().get("items", {}).get(str(health_id), {})
	check(String(final.get("owner", "")) == "first", "Host-selected winner owns the item")
	check(a.get_item_state().get("items", {}).size() == 2, "Pickup never duplicates item records")
	check(String(a.get_item_state().get("items", {}).get(str(jump_id), {}).get("owner", "")) == "", "Other dropped items keep their own ownership")
	first.free(); second.free(); dying.free()

func test_item_use_two_health_modes_and_jump_replay() -> void:
	var a = Authority.new()
	var player = load("res://scene/maincharac.tscn").instantiate()
	player.global_position = Vector2.ZERO
	player.spawn_position = Vector2.ZERO
	root.add_child(player)
	await process_frame
	var other = actor_at(Vector2(24, 0))
	a.register_player(&"user", player)
	a.register_player(&"other", other)
	await physics_frame
	# Health use mode 1: E expands one cell only from a full reserve.
	var expand_id: int = a.grant_item(&"user", "health", 30.0, 30.0)
	player.real_hp = 120.0
	var expand_revision := int(a.get_item(expand_id).get("revision", -1))
	check(a.submit_command(&"user", {"type": "use_item", "item_id": expand_id,
		"mode": "expand", "expected_revision": expand_revision}, 1), "Full health item expands on the host")
	check(is_equal_approx(player.max_hp, 180.0) and is_equal_approx(player.real_hp, 150.0),
		"Health expansion raises the maximum and current health by one cell")
	check(a.get_item(expand_id).is_empty(), "Expanded health item is consumed")
	check(not a.submit_command(&"user", {"type": "use_item", "item_id": expand_id,
		"mode": "expand", "expected_revision": expand_revision}, 2), "Consumed item cannot be used twice")

	# Health use mode 2: a held/partial reserve heals by the host-clamped amount.
	var heal_id: int = a.grant_item(&"user", "health", 12.0, 30.0)
	player.real_hp = 100.0
	var heal_revision := int(a.get_item(heal_id).get("revision", -1))
	check(a.submit_command(&"user", {"type": "use_item", "item_id": heal_id,
		"mode": "heal", "expected_revision": heal_revision, "amount": 5.0}, 3), "Partial health item heals on the host")
	check(is_equal_approx(player.real_hp, 105.0), "Host consumes only the requested heal amount")
	check(is_equal_approx(float(a.get_item(heal_id).get("remaining", 0.0)), 7.0)
		and int(a.get_item(heal_id).get("revision", 0)) > heal_revision,
		"Heal advances the item revision and reserve")
	check(not a.submit_command(&"user", {"type": "use_item", "item_id": heal_id,
		"mode": "heal", "expected_revision": heal_revision, "amount": 5.0}, 4),
		"Stale item revision cannot heal twice")
	check(is_equal_approx(player.real_hp, 105.0)
		and is_equal_approx(float(a.get_item(heal_id).get("remaining", 0.0)), 7.0),
		"Rejected stale use changes neither actor nor item")
	check(a.submit_command(&"user", {"type": "use_item", "item_id": heal_id,
		"mode": "heal", "expected_revision": int(a.get_item(heal_id).get("revision", -1)),
		"amount": 999.0}, 5), "Host clamps an oversized heal request")
	check(is_equal_approx(player.real_hp, 112.0) and a.get_item(heal_id).is_empty(),
		"Oversized heal consumes the remaining reserve and removes the item")

	# Ownership, alive and type/value checks are all host decisions.
	var owned_id: int = a.grant_item(&"user", "health", 30.0, 30.0)
	var owned_revision := int(a.get_item(owned_id).get("revision", -1))
	check(not a.submit_command(&"other", {"type": "use_item", "item_id": owned_id,
		"mode": "heal", "expected_revision": owned_revision, "amount": 5.0}, 6),
		"Another player cannot use an item they do not own")
	check(not a.submit_command(&"user", {"type": "use_item", "item_id": owned_id,
		"mode": "jump", "expected_revision": owned_revision}, 7), "Health item rejects the jump use mode")
	check(not a.submit_command(&"user", {"type": "use_item", "item_id": owned_id,
		"mode": "heal", "amount": 5.0}, 8), "Use without expected_revision is rejected")
	player.is_dead = true
	check(not a.submit_command(&"user", {"type": "use_item", "item_id": owned_id,
		"mode": "heal", "expected_revision": owned_revision, "amount": 5.0}, 9),
		"Dead owner cannot use an item")
	player.is_dead = false

	# Jump use is one-shot and a replayed command consumes nothing more.
	var jump_id: int = a.grant_item(&"user", "jump", 1.0, 1.0)
	var jump_revision := int(a.get_item(jump_id).get("revision", -1))
	check(a.submit_command(&"user", {"type": "use_item", "item_id": jump_id,
		"mode": "jump", "expected_revision": jump_revision}, 10), "Jump item use is accepted")
	check(player.get_motor().extra_air_jumps == 1 and a.get_item(jump_id).is_empty(),
		"Jump item grants exactly one air jump and is consumed")
	check(not a.submit_command(&"user", {"type": "use_item", "item_id": jump_id,
		"mode": "jump", "expected_revision": jump_revision}, 11),
		"Replayed jump command consumes no second item")
	check(player.get_motor().extra_air_jumps == 1, "Replayed jump command cannot stack the bonus")
	player.free(); other.free()

func test_item_slots_world_state_and_revision_cas() -> void:
	var a = Authority.new()
	var owner = actor_at(Vector2.ZERO)
	var full = actor_at(Vector2(20, 0))
	var third = actor_at(Vector2(8, 0))
	var fourth = actor_at(Vector2(-8, 0))
	a.register_player(&"owner", owner)
	a.register_player(&"full", full)
	a.register_player(&"third", third)
	a.register_player(&"fourth", fourth)
	await physics_frame
	owner.respawn_delay = 5.0
	for index in range(3):
		check(a.grant_item(&"owner", "health", 30.0, 30.0) > 0, "Owner receives backpack slot %d" % (index + 1))
	for index in range(3):
		check(a.grant_item(&"full", "jump", 1.0, 1.0) > 0, "Full player receives backpack slot %d" % (index + 1))
	check(a.grant_item(&"full", "health", 30.0, 30.0) == -1, "A full three-slot backpack rejects a fourth item")
	owner.health_component.set_current(2.0)
	check(a.submit_command(&"full", sword(Vector2.LEFT, 900), 1), "Sword kills the item owner")
	step_ticks(a, 8)
	check(owner.is_dead, "Item owner is dead before dropping")
	var state: Dictionary = a.get_item_state()
	var records: Dictionary = state.get("items", {})
	var world_count := 0
	var dropped_id := -1
	var dropped: Dictionary = {}
	for key: Variant in records.keys():
		var record: Dictionary = records[key]
		if String(record.get("state", "")) == "world":
			world_count += 1
			if dropped_id < 0:
				dropped_id = int(record.get("item_id", -1))
				dropped = record
	check(world_count == 3, "Death dropped exactly three owned items")
	check(dropped_id > 0, "A dropped world item is present")
	check(String(dropped.get("state", "")) == "world" and String(dropped.get("owner", "x")) == "",
		"World item exposes state and has no owner")
	var position: Variant = dropped.get("position", null)
	check(position is Dictionary and position.has("x") and position.has("y")
		and (position["x"] is float or position["x"] is int)
		and (position["y"] is float or position["y"] is int),
		"World item exposes numeric JSON-safe x/y position")
	for forbidden in ["node", "resource", "weakref", "texture", "rid", "instance_id", "icon", "holder"]:
		check(not dropped.has(forbidden), "World item state omits forbidden field: " + forbidden)
	var encoded := JSON.stringify(state)
	var decoded: Variant = JSON.parse_string(encoded)
	check(decoded is Dictionary, "World item checkpoint round-trips through JSON")
	if decoded is Dictionary:
		var decoded_item: Dictionary = decoded.get("items", {}).get(str(dropped_id), {})
		check(String(decoded_item.get("state", "")) == "world"
			and is_equal_approx(float(decoded_item.get("position", {}).get("x", INF)), float(position["x"])),
			"JSON round-trip preserves world state and position")
	# The same public checkpoint is what a client CombatReplica receives.
	var client_replica = CombatReplica.new()
	client_replica.configure(7070)
	var packet := {"match_epoch": 7070, "server_tick": a.get_tick(),
		"combat": a.get_combat_state(), "players": a.get_snapshots()}
	check(client_replica.apply_packet(packet), "Client replica accepts the world drop checkpoint")
	var client_item: Dictionary = client_replica.get_item(dropped_id)
	check(String(client_item.get("state", "")) == "world"
		and is_equal_approx(float(client_item.get("position", {}).get("x", INF)), float(position["x"]))
		and is_equal_approx(float(client_item.get("position", {}).get("y", INF)), float(position["y"])),
		"World drop state and position are consistent across the authority/replica boundary")
	check(client_replica.get_world_items().size() == 3, "Client replica exposes all three dropped world items")
	var observed_revision := int(dropped.get("revision", -1))
	check(not a.submit_command(&"full", {"type": "pickup", "item_id": dropped_id,
		"expected_revision": observed_revision}, 2), "Three-slot full player rejects pickup on the host")
	check(String(a.get_item_state().get("items", {}).get(str(dropped_id), {}).get("owner", "x")) == "",
		"Rejected full-backpack pickup leaves the item unowned")
	check(a.submit_command(&"third", {"type": "pickup", "item_id": dropped_id,
		"expected_revision": observed_revision}, 3), "First valid pickup request wins")
	check(not a.submit_command(&"fourth", {"type": "pickup", "item_id": dropped_id,
		"expected_revision": observed_revision}, 4), "Concurrent pickup with the same revision loses")
	var final: Dictionary = a.get_item_state()
	check(String(final.get("items", {}).get(str(dropped_id), {}).get("owner", "")) == "third",
		"Unique pickup winner owns the item")
	check(final.get("items", {}).size() == 6, "Pickup race never duplicates item records")
	owner.free(); full.free(); third.free(); fourth.free()

func test_weapon_damage_ignores_contact_invincibility_fields() -> void:
	var a = Authority.new()
	var attacker = actor_at(Vector2.ZERO)
	var target = actor_at(Vector2(24, 0))
	a.register_player(&"attacker", attacker)
	a.register_player(&"target", target)
	await physics_frame
	target.hitable = false
	target.hitcooltimer = 3.0
	target.contact_invincibility_time = 3.0
	check(a.submit_command(&"attacker", sword(Vector2.RIGHT, 80), 1), "Sword command is accepted against a contact-invincible actor")
	step_ticks(a, 4)
	check(target.real_hp == 148.0, "Weapon damage is not gated by contact-only invincibility")
	check(not target.hitable and target.hitcooltimer == 3.0, "Weapon damage does not start or consume contact invincibility")
	attacker.free(); target.free()
