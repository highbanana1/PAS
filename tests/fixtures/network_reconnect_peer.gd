extends SceneTree

const Session = preload("res://scene/script/network/network_session.gd")
const Bridge = preload("res://scene/script/network/match_network_bridge.gd")
const Actor = preload("res://tests/fixtures/network_combat_actor.gd")

var session
var bridge
var folder: String

func _initialize() -> void:
	run.call_deferred()

func write(name: String, data: Dictionary) -> void:
	var target := folder.path_join(name)
	var pending := target + ".tmp"
	var file := FileAccess.open(pending, FileAccess.WRITE)
	file.store_string(JSON.stringify(data))
	file.close()
	DirAccess.rename_absolute(pending, target)

func read(name: String) -> Dictionary:
	var target := folder.path_join(name)
	if not FileAccess.file_exists(target): return {}
	var value: Variant = JSON.parse_string(FileAccess.get_file_as_string(target))
	return value if value is Dictionary else {}

func wait_until(predicate: Callable, milliseconds: int = 9000) -> bool:
	var until := Time.get_ticks_msec() + milliseconds
	while Time.get_ticks_msec() < until:
		await process_frame
		if predicate.call(): return true
	return false

func make_actor():
	var actor = Actor.new()
	actor.position = Vector2(20, 10)
	root.add_child(actor)
	return actor

func position_matches(value: Variant, expected: Vector2) -> bool:
	if value is Vector2: return (value as Vector2).is_equal_approx(expected)
	if value is Dictionary:
		return Vector2(float(value.get("x", NAN)), float(value.get("y", NAN))).is_equal_approx(expected)
	return false

func run() -> void:
	var args := OS.get_cmdline_user_args()
	if args.size() < 2:
		quit(1); return
	var role := String(args[0])
	folder = String(args[1])
	session = Session.new()
	session.name = "NetworkSession"
	root.add_child(session)
	bridge = Bridge.new()
	bridge.name = "MatchNetworkBridge"
	root.add_child(bridge)
	match role:
		"host": await run_host()
		"host_expiry": await run_host_expiry()
		"initial": await run_initial()
		"intruder": await run_intruder()
		"stale": await run_stale()
		"replacement": await run_replacement()
		"resume": await run_resume()
		_: quit(1)

func run_host() -> void:
	if session.host(0, {"match_epoch": 606606, "seats": 2}) != OK or not bridge.configure(session):
		write("host_error.json", {"error": "host_setup"}); quit(1); return
	var host_id := StringName(String(session.get_local_identity().get("player_id", "")))
	bridge.bind_actor(host_id, make_actor(), true)
	session.player_joined.connect(func(_peer: int, player_id: String) -> void:
		bridge.bind_actor(StringName(player_id), make_actor()))
	session.player_left.connect(func(_peer: int, player_id: String) -> void:
		var actor = bridge.get_bound_actor(StringName(player_id))
		if is_instance_valid(actor): actor.health_component.set_current(120.0)
		if read("left.json").is_empty():
			write("left.json", {"player_id": player_id,
				"reserved": session.is_player_reserved(StringName(player_id)),
				"actor_retained": is_instance_valid(actor),
				"occupied": session.get_occupied_seat_count()}))
	session.player_resumed.connect(func(_peer: int, player_id: String) -> void:
		write("resumed_signal.json", {"player_id": player_id,
			"actor_retained": is_instance_valid(bridge.get_bound_actor(StringName(player_id))) }))
	write("ready.json", {"port": session.get_port()})
	var completed: bool = await wait_until(func() -> bool:
		return not read("resume_final.json").is_empty(), 18000)
	var first: Dictionary = read("first.json")
	var player_id := StringName(String(first.get("identity", {}).get("player_id", "")))
	write("host_final.json", {"completed": completed,
		"player_id": String(player_id), "online": session.is_player_online(player_id),
		"reserved": session.is_player_reserved(player_id),
		"actor_retained": is_instance_valid(bridge.get_bound_actor(player_id)),
		"occupied": session.get_occupied_seat_count()})
	await create_timer(0.2).timeout
	session.stop()
	quit(0 if completed else 1)

func run_initial() -> void:
	var port := int(read("ready.json").get("port", 0))
	if session.join("127.0.0.1", port) != OK or not bridge.configure(session):
		write("initial_error.json", {"error": "initial_join"}); quit(1); return
	var ready: bool = await wait_until(func() -> bool:
		return not session.get_local_identity().is_empty() and bridge.has_baseline())
	if not ready:
		write("initial_error.json", {"error": "initial_baseline"}); quit(1); return
	var identity: Dictionary = session.get_local_identity()
	write("first.json", {"identity": identity,
		"baseline_tick": bridge.get_last_baseline_tick()})
	session.stop()
	quit(0)

func run_host_expiry() -> void:
	if session.host(0, {"match_epoch": 606607, "seats": 2}) != OK or not bridge.configure(session):
		write("expiry_host_error.json", {"error": "host_setup"}); quit(1); return
	var host_id := StringName(String(session.get_local_identity().get("player_id", "")))
	bridge.bind_actor(host_id, make_actor(), true)
	bridge.configure_extraction(120.0)
	bridge.register_star(&"star", Vector2(20, 10))
	bridge.register_extraction_point(&"point", Vector2(20, 10))
	var item_ids: Array[int] = []
	var expired_ids: Array[String] = []
	var joined_ids: Array[String] = []
	session.player_joined.connect(func(_peer: int, player_id: String) -> void:
		joined_ids.append(player_id)
		var id := StringName(player_id)
		bridge.bind_actor(id, make_actor())
		if joined_ids.size() > 1: return
		item_ids.append(bridge.get_authority().grant_item(id, &"health", 30.0, 30.0))
		bridge.get_authority().submit_command(id, {"type": "star_pickup",
			"star_id": "star", "expected_revision": 1})
		bridge.get_authority().submit_command(id, {"type": "deliver_star",
			"point_id": "point", "expected_revision": 2}))
	session.player_left.connect(func(_peer: int, player_id: String) -> void:
		if read("expiry_left.json").is_empty():
			write("expiry_left.json", {"player_id": player_id,
				"reserved": session.is_player_reserved(StringName(player_id)),
				"actor_retained": is_instance_valid(bridge.get_bound_actor(StringName(player_id))),
				"occupied": session.get_occupied_seat_count()}))
	session.player_reservation_expired.connect(func(player_id: String) -> void:
		expired_ids.append(player_id))
	write("ready.json", {"port": session.get_port()})
	var offline: bool = await wait_until(func() -> bool:
		return not read("expiry_left.json").is_empty(), 9000)
	if not offline:
		write("expiry_host_error.json", {"error": "no_disconnect"}); session.stop(); quit(1); return
	var expired: bool = await wait_until(func() -> bool: return not expired_ids.is_empty(), 34000)
	await process_frame
	var player_id := StringName(String(read("expiry_left.json").get("player_id", "")))
	var star: Dictionary = bridge.get_authority().get_extraction_state().get("stars", {}).get("star", {})
	var point: Dictionary = bridge.get_authority().get_extraction_state().get("points", {}).get("point", {})
	var item: Dictionary = bridge.get_authority().get_item(item_ids[0]) if not item_ids.is_empty() else {}
	var star_revision := int(star.get("revision", -1))
	var item_revision := int(item.get("revision", -1))
	write("expiry_state.json", {"expired": expired,
		"event_count": expired_ids.size(),
		"same_player": expired_ids.has(String(player_id)),
		"player_removed": not bridge.get_authority().get_player_ids().has(player_id)
			and not is_instance_valid(bridge.get_bound_actor(player_id)),
		"star_free": String(star.get("state", "")) == "FREE"
			and position_matches(star.get("position"), Vector2(20, 10)),
		"point_free": String(point.get("occupant", "missing")) == "",
		"item_free": String(item.get("state", "")) == "world"
			and position_matches(item.get("position"), Vector2(20, 10)),
		"occupied": session.get_occupied_seat_count()})
	await wait_until(func() -> bool: return not read("stale_final.json").is_empty(), 8000)
	await create_timer(0.2).timeout
	write("expiry_host_final.json", {"event_count": expired_ids.size(),
		"no_duplicate_drop": int(bridge.get_authority().get_extraction_state().get("stars", {})
			.get("star", {}).get("revision", -2)) == star_revision
			and int(bridge.get_authority().get_item(item_ids[0]).get("revision", -2)) == item_revision,
		"occupied": session.get_occupied_seat_count()})
	var replacement_joined: bool = await wait_until(func() -> bool:
		return not read("replacement_final.json").is_empty(), 9000)
	var replacement_id: String = joined_ids[1] if joined_ids.size() > 1 else ""
	var replacement_peer: int = session.get_peer_id_for_player(StringName(replacement_id))
	var replacement_identity: Dictionary = session.get_identity_for_peer(replacement_peer)
	write("replacement_host_final.json", {"joined": replacement_joined,
		"old_player_id": String(player_id), "new_player_id": replacement_id,
		"new_seat": int(replacement_identity.get("seat", -1)),
		"old_actor_absent": not bridge.get_authority().get_player_ids().has(player_id),
		"new_actor_bound": is_instance_valid(bridge.get_bound_actor(StringName(replacement_id))),
		"occupied": session.get_occupied_seat_count(),
		"old_drop_unchanged": int(bridge.get_authority().get_extraction_state().get("stars", {})
			.get("star", {}).get("revision", -2)) == star_revision
			and int(bridge.get_authority().get_item(item_ids[0]).get("revision", -2)) == item_revision})
	session.stop()
	quit(0 if expired and replacement_joined else 1)

func run_stale() -> void:
	var old_identity: Dictionary = read("first.json").get("identity", {})
	var reasons: Array[String] = []
	session.join_failed.connect(func(value: String) -> void: reasons.append(value))
	var port := int(read("ready.json").get("port", 0))
	if session.join("127.0.0.1", port, old_identity) != OK:
		write("stale_final.json", {"error": "connect_failed"}); quit(1); return
	var rejected: bool = await wait_until(func() -> bool: return not reasons.is_empty(), 6000)
	write("stale_final.json", {"rejected": rejected,
		"reason": reasons[0] if rejected else "",
		"no_identity": session.get_local_identity().is_empty()})
	if session.is_active(): session.stop()
	quit(0 if rejected else 1)

func run_replacement() -> void:
	var port := int(read("ready.json").get("port", 0))
	if session.join("127.0.0.1", port) != OK or not bridge.configure(session):
		write("replacement_error.json", {"error": "join_failed"}); quit(1); return
	var ready: bool = await wait_until(func() -> bool:
		return not session.get_local_identity().is_empty() and bridge.has_baseline())
	if not ready:
		write("replacement_error.json", {"error": "baseline_missing"}); quit(1); return
	var identity: Dictionary = session.get_local_identity()
	var old_id := String(read("first.json").get("identity", {}).get("player_id", ""))
	var new_id := String(identity.get("player_id", ""))
	var players: Dictionary = bridge.get_last_baseline().get("players", {})
	write("replacement_final.json", {"player_id": new_id,
		"seat": int(identity.get("seat", -1)),
		"baseline_has_new": players.has(new_id),
		"baseline_excludes_old": not players.has(old_id)})
	await wait_until(func() -> bool: return not read("replacement_host_final.json").is_empty(), 2000)
	session.stop()
	quit(0)

func run_intruder() -> void:
	var first: Dictionary = read("first.json")
	var fake: Dictionary = first.get("identity", {}).duplicate(true)
	fake["reconnect_token"] = "0".repeat(64)
	var reason: Array[String] = []
	session.join_failed.connect(func(value: String) -> void: reason.append(value))
	var port := int(read("ready.json").get("port", 0))
	if session.join("127.0.0.1", port, fake) != OK:
		write("intruder_final.json", {"error": "connect_failed"}); quit(1); return
	var rejected: bool = await wait_until(func() -> bool: return not reason.is_empty(), 5000)
	write("intruder_final.json", {"rejected": rejected,
		"reason": reason[0] if rejected else "",
		"no_identity": session.get_local_identity().is_empty()})
	if session.is_active(): session.stop()
	quit(0 if rejected else 1)

func run_resume() -> void:
	var old_identity: Dictionary = read("first.json").get("identity", {})
	var port := int(read("ready.json").get("port", 0))
	if session.join("127.0.0.1", port, old_identity) != OK or not bridge.configure(session):
		write("resume_error.json", {"error": "resume_join"}); quit(1); return
	var ready: bool = await wait_until(func() -> bool:
		return not session.get_local_identity().is_empty() and bridge.has_baseline())
	if not ready:
		write("resume_error.json", {"error": "resume_baseline"}); quit(1); return
	var identity: Dictionary = session.get_local_identity()
	var baseline: Dictionary = bridge.get_last_baseline()
	var player_id := String(identity.get("player_id", ""))
	var state: Dictionary = baseline.get("players", {}).get(player_id, {})
	write("resume_final.json", {"same_player": player_id == String(old_identity.get("player_id", "")),
		"token_rotated": String(identity.get("reconnect_token", "")) != String(old_identity.get("reconnect_token", "")),
		"baseline_tick": int(baseline.get("baseline_tick", -1)),
		"health": float(state.get("health", -1.0)),
		"life_id": int(identity.get("life_id", -1))})
	await wait_until(func() -> bool: return not read("host_final.json").is_empty(), 2000)
	session.stop()
	quit(0)
