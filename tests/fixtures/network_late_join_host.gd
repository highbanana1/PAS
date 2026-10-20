extends SceneTree

## Real Godot host process for Ticket 02B2A. It advances its authority and
## moves its local player before any client exists, then publishes readiness.
## A late-joining peer is mapped by NetworkSession; MatchNetworkBridge queues
## that peer for one complete reliable baseline built inside a single authority
## tick. The host keeps stepping and broadcasting snapshots until the client
## reports it has observed a strictly higher tick, then it writes its result and
## closes the session.

const SESSION_PATH := "res://scene/script/network/network_session.gd"
const AUTHORITY_PATH := "res://scene/script/network/match_authority.gd"
const BRIDGE_PATH := "res://scene/script/network/match_network_bridge.gd"
const CONTROL_PATH := "res://tests/fixtures/network_late_join_control.gd"
const ACTOR_SCENE := "res://tests/fixtures/network_match_actor.tscn"
const HOST_SPAWN := Vector2(0.0, 150.0)
const REMOTE_SPAWN := Vector2(180.0, 150.0)
const FLOOR_SIZE := Vector2(4000.0, 40.0)
const FLOOR_CENTER := Vector2(0.0, 200.0)
const PRE_ADVANCE_MS := 1500
const PRE_ADVANCE_MIN_X := 90.0

var _session
var _authority
var _bridge
var _control
var _host_actor
var _remote_actor
var _out_path := ""
var _ready_path := ""
var _log_path := ""
var _deadline_ms := 0
var _host_spawn := HOST_SPAWN
var _remote_spawn := REMOTE_SPAWN
var _host_id := ""
var _remote_id := ""
var _client_peer_id := 0
var _pre_join_tick := -1
var _pre_join_position := Vector2.ZERO
var _baseline_sent: Dictionary = {}
var _baseline_tick := -1
var _client_progress: Dictionary = {}
var _client_progress_received := false
var _error := ""
var _exit_code := 0

func _initialize() -> void:
	_run.call_deferred()

func _run() -> void:
	var args := _parse_args(OS.get_cmdline_user_args())
	_out_path = String(args.get("out", ""))
	_ready_path = String(args.get("ready", ""))
	_log_path = String(args.get("log", ""))
	var port := int(args.get("port", "0"))
	var epoch := int(args.get("epoch", "525252"))
	var max_wait := float(args.get("max-wait", "22"))
	_deadline_ms = Time.get_ticks_msec() + int(max_wait * 1000.0)
	_log("starting late-join host fixture (max-wait=%.1fs)" % max_wait)
	if _out_path.is_empty() or _ready_path.is_empty():
		_error = "missing --out/--ready"
		_fail_early(1)
		return

	var control_script = load(CONTROL_PATH)
	var session_script = load(SESSION_PATH)
	var authority_script = load(AUTHORITY_PATH)
	var bridge_script = load(BRIDGE_PATH)
	var actor_scene = load(ACTOR_SCENE)
	if control_script == null or session_script == null or authority_script == null or bridge_script == null or actor_scene == null:
		_error = "a required host fixture module is missing"
		_fail_early(1)
		return
	if not control_script.can_instantiate() or not session_script.can_instantiate() or not authority_script.can_instantiate() or not bridge_script.can_instantiate():
		_error = "a required host fixture module cannot instantiate"
		_fail_early(1)
		return

	_control = control_script.new()
	_control.name = "FixtureControl"
	_control.log_path = _log_path
	root.add_child(_control)
	_control.join_progress_received.connect(_on_client_progress)

	_session = session_script.new()
	_session.name = "NetworkSession"
	root.add_child(_session)
	var host_error: int = _session.host(port, {
		"match_epoch": epoch,
		"seats": int(session_script.MAX_SEATS),
	})
	if host_error != OK:
		_error = "host failed with error %d" % host_error
		_fail_early(1)
		return

	_authority = authority_script.new()
	_bridge = bridge_script.new()
	_bridge.name = "MatchNetworkBridge"
	root.add_child(_bridge)
	if not _bridge.configure(_session, _authority):
		_error = "bridge configuration failed"
		_fail_early(1)
		return
	_bridge.baseline_sent.connect(_on_baseline_sent)
	_session.player_joined.connect(_on_player_joined)

	_create_floor()
	_host_actor = actor_scene.instantiate()
	_host_actor.global_position = HOST_SPAWN
	_host_actor.name = "HostActor"
	root.add_child(_host_actor)
	_remote_actor = actor_scene.instantiate()
	_remote_actor.global_position = REMOTE_SPAWN
	_remote_actor.name = "RemoteActor"
	root.add_child(_remote_actor)
	await process_frame
	_host_spawn = _host_actor.global_position
	_remote_spawn = _remote_actor.global_position
	var host_identity: Dictionary = _session.get_local_identity()
	_host_id = String(host_identity.get("player_id", ""))
	if _host_id.is_empty() or not _bridge.bind_actor(StringName(_host_id), _host_actor, true):
		_error = "host actor binding failed"
		_fail_early(1)
		return
	_log("host actor %s bound at %s" % [_host_id, _host_spawn])

	await _advance_before_join()
	_pre_join_tick = _authority.get_tick()
	_pre_join_position = _host_actor.global_position
	_write_json(_ready_path, {
		"ok": true,
		"port": _session.get_port(),
		"epoch": _session.get_match_epoch(),
		"pid": OS.get_process_id(),
		"host_player_id": _host_id,
		"host_spawn": _vector_json(_host_spawn),
		"pre_join_tick": _pre_join_tick,
		"pre_join_position": _vector_json(_pre_join_position),
	})
	_log("pre-advanced authority to tick %d at %s; listening on port %d" % [_pre_join_tick, _pre_join_position, _session.get_port()])
	await _run_session()

func _advance_before_join() -> void:
	var start := Time.get_ticks_msec()
	var next_move := start
	while Time.get_ticks_msec() - start < PRE_ADVANCE_MS:
		var now := Time.get_ticks_msec()
		if _host_actor.global_position.x - _host_spawn.x >= PRE_ADVANCE_MIN_X:
			break
		if now >= next_move:
			_bridge.submit_command({"type": "move", "direction": Vector2.RIGHT})
			next_move = now + 40
		await create_timer(0.02).timeout
	_bridge.submit_command({"type": "move", "direction": Vector2.ZERO})
	for index in range(8):
		await create_timer(0.02).timeout

func _create_floor() -> void:
	var floor := StaticBody2D.new()
	floor.name = "FixtureFloor"
	floor.position = FLOOR_CENTER
	floor.collision_layer = 1
	floor.collision_mask = 0
	var shape := CollisionShape2D.new()
	var rectangle := RectangleShape2D.new()
	rectangle.size = FLOOR_SIZE
	shape.shape = rectangle
	floor.add_child(shape)
	root.add_child(floor)

func _run_session() -> void:
	while Time.get_ticks_msec() < _deadline_ms and not _client_progress_received:
		await create_timer(0.01).timeout
	var ok := true
	if _remote_id.is_empty():
		_error = "host timed out waiting for the late-joining client"
		ok = false
	elif _baseline_sent.is_empty():
		_error = "host never sent a baseline to the late joiner"
		ok = false
	elif not _client_progress_received:
		_error = "host timed out waiting for the client's post-baseline progress"
		ok = false
	if not _error.is_empty():
		_exit_code = 1
	ok = ok and _error.is_empty()
	_write_result(ok)
	_log("finishing: ok=%s error=%s baseline_tick=%d steps=%d snapshots=%d" % [
		ok,
		_error,
		_baseline_tick,
		_bridge.get_authority_step_count(),
		_bridge.get_snapshot_send_count(),
	])
	_session.stop()
	await create_timer(0.35).timeout
	quit(_exit_code)

func _on_player_joined(peer_id: int, player_id: String) -> void:
	if peer_id <= 1 or _client_peer_id > 0:
		return
	if not _bridge.bind_actor(StringName(player_id), _remote_actor, false):
		_error = "remote actor binding failed for " + player_id
		_log(_error)
		return
	_client_peer_id = peer_id
	_remote_id = player_id
	_log("late-join peer %d bound to %s at %s" % [peer_id, player_id, _remote_spawn])

func _on_baseline_sent(peer_id: int, baseline: Dictionary) -> void:
	if peer_id != _client_peer_id:
		return
	_baseline_sent = baseline.duplicate(true)
	_baseline_tick = int(baseline.get("baseline_tick", baseline.get("server_tick", -1)))
	_log("baseline sent to peer %d at tick %d with %d players" % [
		peer_id,
		_baseline_tick,
		(baseline.get("players", {}) as Dictionary).size(),
	])

func _on_client_progress(progress: Dictionary) -> void:
	if _client_progress_received:
		return
	_client_progress = progress.duplicate(true)
	_client_progress_received = true
	_log("client progress received: %s" % JSON.stringify(progress))

func _write_result(ok: bool) -> void:
	var host_final: Dictionary = _authority.get_snapshot(StringName(_host_id)) if _authority != null and not _host_id.is_empty() else {}
	var remote_final: Dictionary = _authority.get_snapshot(StringName(_remote_id)) if _authority != null and not _remote_id.is_empty() else {}
	var data := {
		"ok": ok,
		"error": _error,
		"port": _session.get_port(),
		"match_epoch": _session.get_match_epoch(),
		"host_identity": _session.get_local_identity(),
		"host_player_id": _host_id,
		"remote_identity": _session.get_identity_for_peer(_client_peer_id) if _client_peer_id > 0 else {},
		"remote_player_id": _remote_id,
		"client_peer_id": _client_peer_id,
		"host_spawn": _vector_json(_host_spawn),
		"remote_spawn": _vector_json(_remote_spawn),
		"pre_join_tick": _pre_join_tick,
		"pre_join_position": _vector_json(_pre_join_position),
		"baseline_tick": _baseline_tick,
		"baseline_sent": _batch_json(_baseline_sent),
		"client_progress": _client_progress,
		"host_final": _state_json(host_final),
		"remote_final": _state_json(remote_final),
		"authority_steps": _bridge.get_authority_step_count() if _bridge != null else 0,
		"snapshots_sent": _bridge.get_snapshot_send_count() if _bridge != null else 0,
		"pid": OS.get_process_id(),
	}
	_write_json(_out_path, data)

func _state_json(state: Dictionary) -> Dictionary:
	if state.is_empty():
		return {}
	var result: Dictionary = state.duplicate(true)
	for key in ["position", "velocity"]:
		var value: Variant = result.get(key)
		if value is Vector2:
			result[key] = _vector_json(value)
	return result

func _batch_json(batch: Dictionary) -> Dictionary:
	if batch.is_empty():
		return {}
	var result := {
		"match_epoch": int(batch.get("match_epoch", -1)),
		"baseline_tick": int(batch.get("baseline_tick", batch.get("server_tick", -1))),
		"server_tick": int(batch.get("server_tick", -1)),
		"players": {},
	}
	var players: Dictionary = batch.get("players", {})
	for player_id: Variant in players:
		result["players"][String(player_id)] = _state_json(players[player_id])
	return result

func _vector_json(value: Vector2) -> Dictionary:
	return {"x": value.x, "y": value.y}

func _fail_early(code: int) -> void:
	_log("failing early: " + _error)
	if not _ready_path.is_empty():
		_write_json(_ready_path, {"ok": false, "error": _error})
	if not _out_path.is_empty():
		_write_json(_out_path, {"ok": false, "error": _error})
	quit(code)

func _parse_args(args: PackedStringArray) -> Dictionary:
	var result: Dictionary = {}
	for raw: String in args:
		var text := raw.trim_prefix("--")
		var split := text.split("=", true, 1)
		if split.size() == 2:
			result[split[0]] = split[1]
	return result

func _log(message: String) -> void:
	var line := "[%d] HOST %s" % [Time.get_ticks_msec(), message]
	print(line)
	if _log_path.is_empty():
		return
	var file: FileAccess = null
	if FileAccess.file_exists(_log_path):
		file = FileAccess.open(_log_path, FileAccess.READ_WRITE)
		if file != null:
			file.seek_end()
	else:
		file = FileAccess.open(_log_path, FileAccess.WRITE)
	if file == null:
		return
	file.store_line(line)
	file.close()

func _write_json(path: String, data: Dictionary) -> void:
	var file := FileAccess.open(path, FileAccess.WRITE)
	if file == null:
		_log("cannot write " + path)
		return
	file.store_string(JSON.stringify(data, "\t"))
	file.close()
