extends SceneTree

const Session = preload("res://scene/script/network/network_session.gd")
const Bridge = preload("res://scene/script/network/match_network_bridge.gd")
const Actor = preload("res://tests/fixtures/network_combat_actor.gd")

var session
var bridge
var folder: String
var role: String
var local_id: String

func _initialize() -> void:
	run.call_deferred()

func write(name: String, data: Dictionary) -> void:
	var file := FileAccess.open(folder.path_join(name + ".tmp"), FileAccess.WRITE)
	file.store_string(JSON.stringify(data))
	file.close()
	DirAccess.rename_absolute(folder.path_join(name + ".tmp"), folder.path_join(name))

func read(name: String) -> Dictionary:
	var path := folder.path_join(name)
	var value: Variant = JSON.parse_string(FileAccess.get_file_as_string(path)) if FileAccess.file_exists(path) else null
	return value if value is Dictionary else {}

func wait_until(predicate: Callable, milliseconds: int = 10000) -> bool:
	var deadline := Time.get_ticks_msec() + milliseconds
	while Time.get_ticks_msec() < deadline:
		await process_frame
		if predicate.call(): return true
	return false

func make_actor(position: Vector2):
	var actor = Actor.new()
	actor.position = position
	root.add_child(actor)
	return actor

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
		await run_host()
	else:
		await run_client()

func run_host() -> void:
	if session.host(0, {"match_epoch": 505505}) != OK or not bridge.configure(session):
		write("host_error.json", {"error": "host_setup"}); quit(1); return
	local_id = String(session.get_local_identity().player_id)
	bridge.bind_actor(StringName(local_id), make_actor(Vector2(120, 0)), true)
	bridge.configure_extraction(0.25)
	bridge.register_star(&"s1", Vector2.ZERO)
	bridge.register_extraction_point(&"p1", Vector2.ZERO)
	session.player_joined.connect(func(_peer_id: int, player_id: String) -> void:
		bridge.bind_actor(StringName(player_id), make_actor(Vector2.ZERO)))
	write("ready.json", {"port": session.get_port()})
	var got_client: bool = await wait_until(func() -> bool: return not read("client_final.json").is_empty(), 15000)
	var state: Dictionary = bridge.get_extraction_state()
	var star: Dictionary = state.get("stars", {}).get("s1", {})
	var client_id := String(star.get("owner", ""))
	var client_snapshot: Dictionary = bridge.get_authority().get_snapshot(StringName(client_id))
	write("host_final.json", {"got_client": got_client,
		"star_state": String(star.get("state", "")), "owner": client_id,
		"extracted": bool(client_snapshot.get("extracted", false)),
		"host_still_active": bridge.submit_move(Vector2.RIGHT) > 0})
	await create_timer(0.2).timeout
	session.stop()
	quit(0 if got_client else 1)

func run_client() -> void:
	var ready: Dictionary = read("ready.json")
	if session.join("127.0.0.1", int(ready.get("port", 0))) != OK or not bridge.configure(session):
		write("client_error.json", {"error": "client_setup"}); quit(1); return
	if not await wait_until(func() -> bool: return bridge.has_baseline() and bridge.get_local_player_id() != &"", 10000):
		write("client_error.json", {"error": "baseline"}); quit(1); return
	local_id = String(bridge.get_local_player_id())
	bridge.bind_actor(StringName(local_id), make_actor(Vector2.ZERO), true)
	var saw_free: bool = await wait_until(func() -> bool:
		return String(bridge.get_star(&"s1").get("state", "")) == "FREE", 4000)
	var submitted_pickup: int = int(bridge.submit_star_pickup(&"s1")) if saw_free else -1
	var carried: bool = await wait_until(func() -> bool:
		return String(bridge.get_star(&"s1").get("state", "")) == "CARRIED", 4000)
	var submitted_delivery: int = int(bridge.submit_star_delivery(&"p1")) if carried else -1
	var extracted: bool = await wait_until(func() -> bool:
		return String(bridge.get_star(&"s1").get("state", "")) == "CONSUMED" \
			and bool(bridge.combat_replica.get_player(local_id).get("extracted", false)), 7000)
	write("client_final.json", {"pickup": submitted_pickup > 0, "carried": carried,
		"delivery": submitted_delivery > 0, "extracted": extracted,
		"spectating": bool(bridge.combat_replica.get_player(local_id).get("spectating", false)),
		"blocked_move": bridge.submit_move(Vector2.RIGHT) == -1})
	await wait_until(func() -> bool: return not read("host_final.json").is_empty(), 3000)
	session.stop()
	quit(0 if extracted else 1)
