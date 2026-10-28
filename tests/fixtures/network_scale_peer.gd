extends SceneTree

## Real-ENet Ticket 08 fixture. One host plus fifteen clients exercise all
## sixteen seats; a final client verifies the room-full handshake.
const Session = preload("res://scene/script/network/network_session.gd")
const Bridge = preload("res://scene/script/network/match_network_bridge.gd")
const Actor = preload("res://tests/fixtures/network_combat_actor.gd")

var folder: String
var role: String
var index: int
var session
var bridge
var actors: Dictionary = {}

func _initialize() -> void:
	run.call_deferred()

func write(name: String, value: Dictionary) -> void:
	var target := folder.path_join(name)
	var temporary := target + ".tmp"
	var file := FileAccess.open(temporary, FileAccess.WRITE)
	if file == null: return
	file.store_string(JSON.stringify(value))
	file.close()
	DirAccess.rename_absolute(temporary, target)

func wait_until(predicate: Callable, timeout_msec: int) -> bool:
	var deadline := Time.get_ticks_msec() + timeout_msec
	while Time.get_ticks_msec() < deadline:
		if predicate.call(): return true
		await create_timer(0.02).timeout
	return bool(predicate.call())

func run() -> void:
	var args := OS.get_cmdline_user_args()
	if args.size() < 2: quit(2); return
	role = args[0]
	folder = args[1]
	index = int(args[2]) if args.size() > 2 else 0
	if role == "host": await run_host()
	elif role == "client": await run_client(false)
	elif role == "overflow": await run_client(true)
	else: quit(2)

func run_host() -> void:
	session = Session.new()
	root.add_child(session)
	bridge = Bridge.new()
	root.add_child(bridge)
	session.player_joined.connect(_host_joined)
	var error: int = session.host(0, {"seats": 16, "match_epoch": 808016})
	if error != OK or not bridge.configure(session):
		write("host_error.json", {"error": error}); quit(1); return
	_bind_actor(String(session.get_local_identity().get("player_id", "")), 1)
	# Force at least one revisioned reliable-domain packet so the scale sample
	# measures that stream as well as the periodic movement stream.
	bridge.submit_guard(true, Vector2.RIGHT)
	write("ready.json", {"port": session.get_port(), "pid": OS.get_process_id()})
	var full := await wait_until(func() -> bool: return session.get_player_count() == 16, 12000)
	if full:
		write("full.json", {"players": session.get_player_count(),
			"occupied": session.get_occupied_seat_count()})
	await create_timer(5.0).timeout
	var metrics: Dictionary = bridge.get_network_metrics()
	var player_count: int = session.get_player_count()
	var occupied_seats: int = session.get_occupied_seat_count()
	var retained_full_room := full and player_count == 16 and occupied_seats == 16
	write("host_result.json", {"ok": retained_full_room, "players": player_count,
		"occupied": occupied_seats, "actors": actors.size(),
		"last_tick": bridge.get_last_snapshot_tick(), "metrics": metrics,
		"os": OS.get_name(), "processor_count": OS.get_processor_count(),
		"duration_seconds": 5.0})
	session.stop()
	quit(0 if full else 1)

func _host_joined(peer_id: int, player_id: String) -> void:
	var identity: Dictionary = session.get_identity_for_peer(peer_id)
	_bind_actor(player_id, int(identity.get("seat", 1)))

func _bind_actor(player_id: String, seat: int) -> void:
	if player_id.is_empty() or actors.has(player_id): return
	var actor = Actor.new()
	actor.position = Vector2(float(seat) * 32.0, 0.0)
	root.add_child(actor)
	if bridge.bind_actor(StringName(player_id), actor): actors[player_id] = actor

func run_client(expect_rejection: bool) -> void:
	var ready: Dictionary = read("ready.json")
	var port := int(ready.get("port", 0))
	if port <= 0: quit(1); return
	session = Session.new()
	root.add_child(session)
	bridge = Bridge.new()
	root.add_child(bridge)
	var reasons: Array[String] = []
	session.join_failed.connect(func(reason: String) -> void: reasons.append(reason))
	var error: int = session.join("127.0.0.1", port)
	if error != OK or not bridge.configure(session):
		write(result_name(expect_rejection), {"ok": false, "error": error}); quit(1); return
	if expect_rejection:
		var rejected := await wait_until(func() -> bool: return not reasons.is_empty(), 7000)
		write(result_name(true), {"ok": rejected and reasons[0] == "room_full",
			"reason": reasons[0] if rejected else "timeout",
			"no_identity": session.get_local_identity().is_empty()})
		quit(0 if rejected and reasons[0] == "room_full" else 1)
		return
	var converged := await wait_until(func() -> bool:
		return bridge.has_baseline() and bridge.get_replica_states().size() == 16 \
			and bridge.get_applied_snapshot_count() >= 1, 14000)
	# Keep every occupied seat online for the host's complete five-second sample.
	# Exiting as soon as one client converges turns the load test into a shrinking
	# room and makes broadcasts race already-closed ENet peers.
	var sampled := await wait_until(func() -> bool:
		return not read("host_result.json").is_empty(), 10000)
	write(result_name(false), {"ok": converged and sampled,
		"player_id": String(session.get_local_identity().get("player_id", "")),
		"players": bridge.get_replica_states().size(),
		"applied_snapshots": bridge.get_applied_snapshot_count(),
		"last_tick": bridge.get_last_snapshot_tick(),
		"last_batch_players": bridge.get_last_applied_batch().get("players", {}).size()})
	if session.is_active(): session.stop()
	quit(0 if converged and sampled else 1)

func result_name(overflow: bool) -> String:
	return "overflow.json" if overflow else "client_%02d.json" % index

func read(name: String) -> Dictionary:
	var target := folder.path_join(name)
	if not FileAccess.file_exists(target): return {}
	var value: Variant = JSON.parse_string(FileAccess.get_file_as_string(target))
	return value if value is Dictionary else {}
