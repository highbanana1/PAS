extends SceneTree
## Two-process Ticket 04 fixture. Host owns sword/guard/death/items; client
## submits intent through the real NetworkSession command envelope and observes
## the authoritative replica over real ENet.

const Session = preload("res://scene/script/network/network_session.gd")
const Bridge = preload("res://scene/script/network/match_network_bridge.gd")
const Actor = preload("res://tests/fixtures/network_combat_actor.gd")

var session
var bridge
var folder: String
var role: String
var host_id: String
var client_id: String
var host_actor
var client_actor
var failures: int = 0

func _initialize() -> void:
	run.call_deferred()

func check(ok: bool, label: String) -> void:
	if not ok:
		failures += 1
		print("FIXTURE FAIL: ", label)

func write(name: String, data: Dictionary) -> void:
	var f := FileAccess.open(folder.path_join(name + ".tmp"), FileAccess.WRITE)
	f.store_string(JSON.stringify(data))
	f.close()
	DirAccess.rename_absolute(folder.path_join(name + ".tmp"), folder.path_join(name))

func read(name: String) -> Dictionary:
	var path := folder.path_join(name)
	if not FileAccess.file_exists(path):
		return {}
	var value: Variant = JSON.parse_string(FileAccess.get_file_as_string(path))
	return value if value is Dictionary else {}

func make_actor(position: Vector2):
	var actor = Actor.new()
	actor.position = position
	root.add_child(actor)
	return actor

func wait_frames(count: int) -> void:
	for index in range(count):
		await physics_frame

func all_drops_unowned() -> bool:
	var items := host_items()
	if items.size() != 2:
		return false
	for key: Variant in items.keys():
		if String(items[key].get("owner", "x")) != "":
			return false
	return true

func wait_until(predicate: Callable, timeout_ms: int) -> bool:
	var deadline := Time.get_ticks_msec() + timeout_ms
	while Time.get_ticks_msec() < deadline:
		await process_frame
		if predicate.call():
			return true
	return false

func run() -> void:
	var args := OS.get_cmdline_user_args()
	role = args[0]
	folder = args[1]
	session = Session.new()
	session.name = "NetworkSession"
	root.add_child(session)
	bridge = Bridge.new()
	bridge.name = "MatchNetworkBridge"
	root.add_child(bridge)
	if role == "host":
		if session.host(0, {"match_epoch": 404404}) != OK:
			quit(1)
			return
		bridge.configure(session)
		host_id = String(session.get_local_identity().player_id)
		host_actor = make_actor(Vector2.ZERO)
		bridge.bind_actor(StringName(host_id), host_actor, true)
		session.player_joined.connect(_on_player_joined)
		write("ready.json", {"port": session.get_port(), "host_id": host_id})
		await run_host()
	else:
		var ready := read("ready.json")
		host_id = String(ready.get("host_id", ""))
		session.join("127.0.0.1", int(ready.get("port", 0)))
		bridge.configure(session)
		await run_client()

func _on_player_joined(_peer_id: int, player_id: String) -> void:
	client_id = player_id
	client_actor = make_actor(Vector2(24, 0))
	client_actor.respawn_delay = 5.0
	bridge.bind_actor(StringName(client_id), client_actor)

func wait_client_ready() -> bool:
	return await wait_until(func() -> bool: return not read("client_ready.json").is_empty(), 8000)

func wait_observation(predicate: Callable, timeout_ms: int = 6000) -> bool:
	return await wait_until(func() -> bool:
		var obs := read("client_obs.json")
		return not obs.is_empty() and predicate.call(obs), timeout_ms)

func host_guard() -> Dictionary:
	return bridge.get_guard_state(StringName(client_id))

func host_snapshot() -> Dictionary:
	return bridge.get_authority().get_snapshot(StringName(client_id))

func host_items() -> Dictionary:
	return bridge.get_item_state().get("items", {})

func advance_ticks(count: int) -> void:
	for index in range(count):
		bridge.get_authority().step()
	await wait_frames(3)

## Steps the fixed authority clock without yielding, stopping exactly on the
## first tick that satisfies the predicate. Used where the next real frame may
## immediately consume a fresh client command and move the observed value.
func step_until(predicate: Callable, max_ticks: int) -> bool:
	for index in range(max_ticks):
		bridge.get_authority().step()
		if predicate.call():
			return true
	return false

func write_phase(phase: String, item_id: int = -1) -> void:
	write("phase.json", {"phase": phase, "item_id": item_id})

func run_host() -> void:
	var deadline := Time.get_ticks_msec() + 24000
	var result: Dictionary = {"host_id": host_id}
	check(await wait_client_ready(), "client applied baseline")
	check(not client_id.is_empty() and is_instance_valid(client_actor), "host bound the joining client actor")
	if client_id.is_empty() or not is_instance_valid(client_actor):
		write("host_error.json", {"error": "no_client"})
		session.stop()
		quit(1)
		return

	# (1) Sword hit through a real client command envelope.
	write_phase("sword")
	var sword_seen := await wait_observation(func(obs): return int(obs.get("host_health", -1)) == 148, 8000)
	result["sword_hit"] = sword_seen
	result["host_health_after_sword"] = int(host_actor.real_hp)

	# (2) Directional guard: client faces the host and blocks one melee swing.
	write_phase("block")
	var guard_raised := await wait_until(func() -> bool: return bool(host_guard().get("is_guarding", false)), 6000)
	check(guard_raised, "client guard entered host authority")
	bridge.submit_sword(Vector2.RIGHT, 2001)
	await wait_frames(8)
	var blocked_guard := host_guard()
	result["block_raised"] = guard_raised
	result["block_health"] = float(client_actor.real_hp)
	result["block_guard_value"] = float(blocked_guard.get("value", 0.0))
	result["block_guarding"] = bool(blocked_guard.get("is_guarding", false))
	result["block_observed"] = await wait_observation(func(obs): return float(obs.get("own_health", 0.0)) == 150.0 and float(obs.get("guard_value", 100.0)) < 90.0, 6000)

	# (3) Guard drain, exhaustion lock and full recovery. The client keeps
	# requesting guard so the exhausted lock has a live request to refuse.
	write_phase("deplete")
	await wait_until(func() -> bool: return bool(host_guard().get("is_guarding", false)), 6000)
	await advance_ticks(610)
	var depleted := host_guard()
	result["depleted_exhausted"] = bool(depleted.get("exhausted", false))
	result["depleted_guarding"] = bool(depleted.get("is_guarding", true))
	result["depleted_value"] = float(depleted.get("value", -1.0))
	write_phase("recover")
	await advance_ticks(430)
	var mid := host_guard()
	result["mid_exhausted"] = bool(mid.get("exhausted", false))
	result["mid_guarding"] = bool(mid.get("is_guarding", true))
	result["mid_value"] = float(mid.get("value", 0.0))
	var full_reached := step_until(func() -> bool:
		var guard := host_guard()
		return is_equal_approx(float(guard.get("value", 0.0)), 100.0) \
			and not bool(guard.get("exhausted", true)), 600)
	var full := host_guard()
	result["full_reached"] = full_reached
	result["full_value"] = float(full.get("value", 0.0))
	result["full_exhausted"] = bool(full.get("exhausted", true))
	var unlocked := await wait_until(func() -> bool: return bool(host_guard().get("is_guarding", false)), 4000)
	result["recovered_guarding"] = unlocked

	# (4) Stable item checkpoint before death.
	write_phase("grant")
	var health_id: int = bridge.grant_item(StringName(client_id), "health", 12.0, 30.0)
	var jump_id: int = bridge.grant_item(StringName(client_id), "jump", 1.0, 1.0)
	var granted := await wait_observation(func(obs):
		var items: Dictionary = obs.get("items", {})
		return items.size() == 2, 6000)
	result["health_item_id"] = health_id
	result["jump_item_id"] = jump_id
	result["items_granted"] = granted
	result["item_checkpoint"] = bridge.get_item_state()

	# (5) Death: stop guard, make the client one cell from death, then kill it
	# with an authoritative sword swing.
	write_phase("death")
	var lowered := await wait_until(func() -> bool: return not bool(host_guard().get("is_guarding", true)), 4000)
	result["death_guard_lowered"] = lowered
	client_actor.health_component.set_current(2.0)
	host_actor.set_physics_process(true)
	bridge.submit_move(Vector2.RIGHT)
	bridge.submit_sword(Vector2.RIGHT, 3001)
	var died := await wait_until(func() -> bool: return bool(host_snapshot().get("dead", false)), 5000)
	result["death_dead"] = died
	result["death_life"] = int(host_snapshot().get("life_id", 0))
	# Wait on the authoritative condition instead of a fixed frame count: the
	# actor can be dead before the next authority tick processes exactly-once
	# drops, which previously made this observation racy.
	var drops_settled := await wait_until(all_drops_unowned, 4000)
	result["drops_settled"] = drops_settled
	var dropped := host_items()
	result["drop_count"] = dropped.size()
	var drop_owner_empty := true
	for key: Variant in dropped.keys():
		if String(dropped[key].get("owner", "x")) != "":
			drop_owner_empty = false
	result["drop_owner_empty"] = drop_owner_empty
	write_phase("dead")
	var world_before: Vector2 = host_actor.global_position
	await advance_ticks(40)
	result["world_kept_running"] = host_actor.global_position.x > world_before.x + 1.0
	result["after_dead_count"] = host_items().size()

	# (6) Authority-clocked five-second respawn.
	await advance_ticks(320)
	await wait_frames(8)
	var respawned := await wait_until(func() -> bool:
		var snap := host_snapshot()
		return not bool(snap.get("dead", true)) and int(snap.get("life_id", 0)) == 2, 6000)
	result["respawned"] = respawned
	result["respawn_life"] = int(host_snapshot().get("life_id", 0))
	result["respawn_health"] = float(host_snapshot().get("health", 0.0))
	result["respawn_guard"] = bridge.get_guard_state(StringName(client_id))
	var client_respawn_seen := await wait_observation(func(obs):
		return int(obs.get("own_life_id", 0)) == 2 and float(obs.get("own_health", 0.0)) == 150.0 and not bool(obs.get("own_dead", true)), 8000)
	result["client_respawn_seen"] = client_respawn_seen

	# (7) Single-winner pickup: host request is ordered first, client's
	# competing request cannot steal or duplicate the item.
	host_actor.set_physics_process(false)
	bridge.submit_move(Vector2.ZERO)
	host_actor.global_position = Vector2.ZERO
	await process_frame
	bridge.submit_pickup(health_id)
	var host_won := await wait_until(func() -> bool:
		var item: Dictionary = host_items().get(str(health_id), {})
		return String(item.get("owner", "")) == host_id, 4000)
	result["host_pickup_won"] = host_won
	write_phase("pickup", health_id)
	var client_tried := await wait_observation(func(obs): return bool(obs.get("pickup_attempted", false)), 5000)
	await create_timer(0.4).timeout
	var final_items := host_items()
	var health_final: Dictionary = final_items.get(str(health_id), {})
	result["pickup_owner"] = String(health_final.get("owner", ""))
	result["pickup_count"] = final_items.size()
	result["client_pickup_attempted"] = client_tried
	result["client_item_owner"] = await wait_observation(func(obs):
		var items: Dictionary = obs.get("items", {})
		return String(items.get(str(health_id), {}).get("owner", "")) == host_id, 5000)

	write_phase("final")
	var client_done := await wait_until(func() -> bool: return not read("client_final.json").is_empty(), 6000)
	result["client_final"] = client_done
	result["failures"] = failures
	write("host_final.json", result)
	if not client_done:
		write("host_error.json", {"error": "client_final_timeout"})
	await create_timer(0.2).timeout
	session.stop()
	quit(0 if failures == 0 else 1)

func run_client() -> void:
	var deadline := Time.get_ticks_msec() + 22000
	var local_id := ""
	var last_guard := 0
	var sword_sent := false
	var death_guard_sent := false
	var pickup_sent := false
	var item_id := -1
	var pickup_attempted := false
	while Time.get_ticks_msec() < deadline:
		await process_frame
		var identity: Dictionary = session.get_local_identity()
		local_id = String(identity.get("player_id", ""))
		if bridge.has_baseline() and not local_id.is_empty():
			if read("client_ready.json").is_empty():
				write("client_ready.json", {"player_id": local_id})
			var phase_data := read("phase.json")
			var phase := String(phase_data.get("phase", ""))
			if phase == "sword" and not sword_sent:
				# Aim left from (24,0) toward the host at the origin.
				if bridge.submit_sword(Vector2.LEFT, 1001) > 0:
					sword_sent = true
			if phase in ["block", "deplete", "recover"]:
				var now := Time.get_ticks_msec()
				if now - last_guard > 80:
					last_guard = now
					bridge.submit_guard(true, Vector2.LEFT)
			if phase == "death" and not death_guard_sent:
				bridge.submit_guard(false)
				death_guard_sent = true
			if phase == "pickup" and not pickup_sent:
				item_id = int(phase_data.get("item_id", -1))
				if int(identity.get("life_id", 0)) >= 2 and item_id > 0:
					bridge.submit_pickup(item_id)
					pickup_sent = true
					pickup_attempted = true
			var own: Dictionary = bridge.get_replica_state(StringName(local_id))
			var own_guard: Dictionary = bridge.get_guard_state(StringName(local_id))
			var item_state: Dictionary = bridge.get_item_state()
			var items: Dictionary = item_state.get("items", {})
			var host_state: Dictionary = bridge.get_replica_state(StringName(host_id))
			write("client_obs.json", {
				"own_health": float(own.get("health", 0.0)),
				"own_dead": bool(own.get("dead", false)),
				"own_life_id": int(own.get("life_id", 0)),
				"host_health": float(host_state.get("health", 0.0)),
				"guard_value": float(own_guard.get("value", 0.0)),
				"guard_exhausted": bool(own_guard.get("exhausted", false)),
				"guard_is_guarding": bool(own_guard.get("is_guarding", false)),
				"items": items,
				"pickup_attempted": pickup_attempted,
			})
			if phase == "final":
				var final := {
					"own_health": float(own.get("health", 0.0)),
					"own_dead": bool(own.get("dead", false)),
					"own_life_id": int(own.get("life_id", 0)),
					"host_health": float(host_state.get("health", 0.0)),
					"guard": own_guard,
					"items": items,
					"local_identity": identity,
					"pickup_attempted": pickup_attempted,
					"failures": failures,
				}
				write("client_final.json", final)
				await create_timer(0.3).timeout
				session.stop()
				quit(0 if failures == 0 else 1)
				return
	write("client_error.json", {"error": "timeout", "local_id": local_id, "failures": failures})
	session.stop()
	quit(1)
