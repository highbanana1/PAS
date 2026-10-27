extends SceneTree

# Drives the public MatchAuthority seam only: registration, bound commands,
# fixed steps, snapshots and lifecycle events. The adapter check proves local
# input enters that same path instead of moving the actor directly.
const PLAYER_SCENE := "res://scene/maincharac.tscn"
const AUTHORITY_PATH := "res://scene/script/network/match_authority.gd"
const ADAPTER_PATH := "res://scene/script/network/offline_authority_adapter.gd"

var failures: Array[String] = []

func _initialize() -> void:
	_run.call_deferred()

func check(ok: bool, label: String) -> void:
	print(("PASS: " if ok else "FAIL: ") + label)
	if not ok:
		failures.append(label)

func _finish() -> void:
	print("RESULT: ", failures.size(), " failures")
	quit(0 if failures.is_empty() else 1)

func _has_event(events: Array, type: String, player_id: String) -> bool:
	for event in events:
		if event is Dictionary \
				and String(event.get("type", "")) == type \
				and String(event.get("player_id", "")) == player_id:
			return true
	return false

func _position_of(snapshot: Dictionary) -> Vector2:
	return snapshot.get("position", Vector2.ZERO)

func _velocity_of(snapshot: Dictionary) -> Vector2:
	return snapshot.get("velocity", Vector2.ZERO)

func _run() -> void:
	var AuthorityScript = load(AUTHORITY_PATH)
	check(AuthorityScript != null and AuthorityScript.can_instantiate(), "MatchAuthority exposes a loadable public module")
	if AuthorityScript == null or not AuthorityScript.can_instantiate():
		_finish()
		return
	await _test_authority_interface(AuthorityScript)
	await _test_unregister_and_invalid(AuthorityScript)
	await _test_dead_actions(AuthorityScript)
	await _test_offline_adapter()
	_finish()

func _test_authority_interface(AuthorityScript: Script) -> void:
	var authority = AuthorityScript.new()
	var player = load(PLAYER_SCENE).instantiate()
	player.global_position = Vector2.ZERO
	player.spawn_position = Vector2.ZERO
	root.add_child(player)
	await process_frame
	var player_id := &"offline-player"
	check(authority.register_player(player_id, player), "MatchAuthority registers a player with a bound id")
	var events: Array = authority.drain_events()
	check(_has_event(events, "player_registered", "offline-player"), "Registration emits an observable lifecycle event")

	check(authority.submit_command(player_id, {"type": "move", "direction": Vector2.RIGHT}), "Move command is accepted")
	for index in range(6):
		authority.step()
	var snapshot: Dictionary = authority.get_snapshot(player_id)
	check(not snapshot.is_empty(), "Snapshot is available after fixed steps")
	check(_position_of(snapshot).x > 5.0, "Fixed-step movement advances the authoritative position")
	check(is_equal_approx(_velocity_of(snapshot).x, 150.0), "Snapshot preserves original movement speed")

	check(authority.submit_command(player_id, {"type": "jump"}), "Jump command is accepted")
	authority.step()
	snapshot = authority.get_snapshot(player_id)
	check(is_equal_approx(_velocity_of(snapshot).y, -400.0), "Snapshot reports the original jump impulse")
	check(int(snapshot.get("jump_count", 1)) == 0, "Snapshot reports the consumed jump")

	for index in range(13):
		authority.step()
	check(authority.submit_command(player_id, {"type": "dash", "direction": Vector2.RIGHT}), "Dash command is accepted")
	authority.step()
	snapshot = authority.get_snapshot(player_id)
	check(bool(snapshot.get("is_dashing", false)), "Snapshot reports an active dash")
	check(is_equal_approx(_velocity_of(snapshot).x, 360.0), "Snapshot preserves original dash speed")

	for index in range(13):
		authority.step()
	player.is_locally_controlled = false
	Input.action_press("right")
	var before_remote: Vector2 = _position_of(authority.get_snapshot(player_id))
	check(authority.submit_command(player_id, {"type": "move", "direction": Vector2.LEFT}), "Explicit command is accepted for a non-local player")
	for index in range(4):
		authority.step()
	Input.action_release("right")
	snapshot = authority.get_snapshot(player_id)
	check(_velocity_of(snapshot).x < 0.0 and _position_of(snapshot).x < before_remote.x, "Non-local player advances from authority commands without local keyboard input")

	player.respawn_delay = 0.1
	for index in range(9):
		player.take_damage(player.max_hp)
		if player.is_dead:
			break
	authority.step()
	events = authority.drain_events()
	check(_has_event(events, "player_died", "offline-player"), "Death is observable through MatchAuthority events")
	snapshot = authority.get_snapshot(player_id)
	check(bool(snapshot.get("dead", false)), "Snapshot exposes the dead state")
	for index in range(8):
		authority.step()
	events = authority.drain_events()
	check(_has_event(events, "player_respawned", "offline-player"), "Respawn is observable through MatchAuthority events")
	snapshot = authority.get_snapshot(player_id)
	check(not bool(snapshot.get("dead", true)) and is_equal_approx(float(snapshot.get("health", 0.0)), 150.0), "Snapshot reports five-cell respawn health")

	player.free()
	await process_frame

func _test_unregister_and_invalid(AuthorityScript: Script) -> void:
	var authority = AuthorityScript.new()
	var first = load(PLAYER_SCENE).instantiate()
	first.global_position = Vector2(40, 0)
	root.add_child(first)
	var replacement = load(PLAYER_SCENE).instantiate()
	replacement.global_position = Vector2(80, 0)
	root.add_child(replacement)
	await process_frame
	var player_id := &"reconnect-player"
	check(authority.register_player(player_id, first), "Lifecycle fixture registers the first actor")
	authority.drain_events()
	check(authority.submit_command(player_id, {"type": "jump"}), "Lifecycle fixture queues a jump")
	check(authority.submit_command(player_id, {"type": "dash", "direction": Vector2.RIGHT}), "Lifecycle fixture queues a dash")
	first.free()
	await process_frame
	check(authority.get_snapshot(player_id).is_empty(), "Snapshot for a freed actor is empty")
	check(not authority.submit_command(player_id, {"type": "jump"}), "Freed actor rejects jump commands")
	check(not authority.submit_command(player_id, {"type": "dash", "direction": Vector2.RIGHT}), "Freed actor rejects dash commands")
	authority.step()
	check(authority.unregister_player(player_id), "Unregister succeeds for a registered player")
	check(not authority.unregister_player(player_id), "Repeated unregister is safe and reports false")
	var events: Array = authority.drain_events()
	check(_has_event(events, "player_unregistered", "reconnect-player"), "Unregister emits player_unregistered")
	check(authority.get_snapshot(player_id).is_empty(), "Snapshot is empty after unregister")
	var replacement_position: Vector2 = replacement.global_position
	check(authority.register_player(player_id, replacement), "Same player id can bind a replacement actor")
	var snapshot: Dictionary = authority.get_snapshot(player_id)
	check(not snapshot.is_empty() and _position_of(snapshot).is_equal_approx(replacement_position), "Replacement actor is the new snapshot source")
	for index in range(2):
		authority.step()
	snapshot = authority.get_snapshot(player_id)
	check(not bool(snapshot.get("is_dashing", false)), "A pre-reconnect dash is not replayed")
	check(int(snapshot.get("jump_count", -1)) == 1, "A pre-reconnect jump is not replayed")
	check(_velocity_of(snapshot).y > -100.0, "Replacement actor starts without a replayed jump impulse")
	check(authority.unregister_player(player_id), "Replacement actor can be unregistered")
	replacement.free()
	await process_frame

func _test_dead_actions(AuthorityScript: Script) -> void:
	var authority = AuthorityScript.new()
	var player = load(PLAYER_SCENE).instantiate()
	player.global_position = Vector2.ZERO
	player.respawn_delay = 0.05
	root.add_child(player)
	await process_frame
	var player_id := &"dead-command-player"
	check(authority.register_player(player_id, player), "Death fixture registers a player")
	authority.drain_events()
	check(authority.submit_command(player_id, {"type": "jump"}), "Jump can be queued before death")
	check(authority.submit_command(player_id, {"type": "dash", "direction": Vector2.RIGHT}), "Dash can be queued before death")
	for index in range(9):
		player.take_damage(player.max_hp)
		if player.is_dead:
			break
	check(player.is_dead, "Death fixture kills the actor")
	check(not authority.submit_command(player_id, {"type": "jump"}), "Dead actor rejects jump commands")
	check(not authority.submit_command(player_id, {"type": "dash", "direction": Vector2.RIGHT}), "Dead actor rejects dash commands")
	authority.step()
	var events: Array = authority.drain_events()
	check(_has_event(events, "player_died", "dead-command-player"), "Death emits a lifecycle event")
	var respawned := false
	for index in range(10):
		authority.step()
		events = authority.drain_events()
		if _has_event(events, "player_respawned", "dead-command-player"):
			respawned = true
			break
	check(respawned, "Authority respawns the dead actor")
	authority.step()
	var snapshot: Dictionary = authority.get_snapshot(player_id)
	check(not snapshot.is_empty() and not bool(snapshot.get("dead", true)), "Respawned snapshot is alive")
	check(not bool(snapshot.get("is_dashing", false)), "A queued dash does not replay after respawn")
	check(int(snapshot.get("jump_count", -1)) == 1, "A queued jump does not replay after respawn")
	check(_velocity_of(snapshot).y > -100.0, "Respawned actor keeps no jump impulse")
	check(authority.unregister_player(player_id), "Dead-command player can be unregistered")
	player.free()
	await process_frame

func _test_offline_adapter() -> void:
	var AdapterScript = load(ADAPTER_PATH)
	check(AdapterScript != null and AdapterScript.can_instantiate(), "Offline authority adapter exposes a loadable public module")
	if AdapterScript == null or not AdapterScript.can_instantiate():
		return
	var adapter = AdapterScript.new()
	root.add_child(adapter)
	var player = load(PLAYER_SCENE).instantiate()
	player.global_position = Vector2(200, 0)
	root.add_child(player)
	await process_frame
	var player_id: StringName = adapter.bind_actor(player, &"local-player")
	check(player_id == &"local-player", "Offline adapter binds a local player")
	check(player.authority_controlled, "Local player is marked authority-driven")

	adapter.set_physics_process(false)
	var frozen: Vector2 = player.global_position
	Input.action_press("right")
	player._physics_process(1.0 / 60.0)
	check(player.global_position == frozen, "Local player cannot bypass the authority with direct input")
	adapter.set_physics_process(true)
	var before: Vector2 = _position_of(adapter.authority.get_snapshot(player_id))
	for index in range(8):
		await physics_frame
	Input.action_release("right")
	var snapshot: Dictionary = adapter.authority.get_snapshot(player_id)
	check(_position_of(snapshot).x > before.x + 5.0, "Offline adapter converts local input into queued authority movement")
	check(is_equal_approx(_velocity_of(snapshot).x, 150.0), "Adapter-driven movement keeps the original speed")

	adapter.authority.drain_events()
	check(adapter.unbind_actor(player), "Offline adapter unbinds a bound actor")
	check(not adapter.unbind_actor(player), "Repeated unbind is safe and reports false")
	check(not adapter.unbind_actor(null), "Unbinding an unknown actor reports false")
	var events: Array = adapter.authority.drain_events()
	check(_has_event(events, "player_unregistered", "local-player"), "Unbind emits player_unregistered")
	check(adapter.authority.get_snapshot(player_id).is_empty(), "Unbound player snapshot is empty")
	check(adapter.bind_actor(player, player_id) == player_id, "Same player id can bind again after unbind")
	check(not adapter.authority.get_snapshot(player_id).is_empty(), "Rebound player snapshot is available")
	check(adapter.unbind_actor(player), "Rebound player can be unbound")

	adapter.free()
	player.free()
	await process_frame
