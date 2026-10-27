extends SceneTree

## Real Godot process that hosts the Ticket 02B1 scenario. NetworkSession owns
## the ENet transport and authoritative identity mapping; MatchNetworkBridge
## drains the validated command queue into MatchAuthority at 60 Hz and sends
## snapshot batches over the unreliable_ordered snapshot channel at 20 Hz. The
## host player's own input enters the same NetworkSession envelope queue. A
## fixture-only reliable control node coordinates the final tick and shutdown,
## never the snapshot payload.

const SESSION_PATH := "res://scene/script/network/network_session.gd"
const AUTHORITY_PATH := "res://scene/script/network/match_authority.gd"
const BRIDGE_PATH := "res://scene/script/network/match_network_bridge.gd"
const CONTROL_PATH := "res://tests/fixtures/network_match_control.gd"
const ACTOR_SCENE := "res://tests/fixtures/network_match_actor.tscn"
const HOST_SPAWN := Vector2(0.0, 150.0)
const REMOTE_SPAWN := Vector2(180.0, 150.0)
const MOTION_REMOTE_SPAWN := Vector2(620.0, 150.0)
const FLOOR_SIZE := Vector2(4000.0, 40.0)
const FLOOR_CENTER := Vector2(0.0, 200.0)
const MOTION_TARGET_MS := 3000

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
var _scenario_start_ms := -1
var _next_move_ms := 0
var _jump_sent := false
var _dash_sent := false
var _stop_sent := false
var _remote_killed := false
var _target_tick := -1
var _target_sent := false
var _client_peer_id := 0
var _remote_id := ""
var _client_done := false
var _client_done_tick := -1
var _host_commands_sent := 0
var _forged_claims: Array = []
var _host_spawn := HOST_SPAWN
var _remote_spawn := REMOTE_SPAWN
var _motion_mode := false
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
	var epoch := int(args.get("epoch", "424242"))
	var max_wait := float(args.get("max-wait", "18"))
	_motion_mode = String(args.get("motion", "0")) == "1"
	if _motion_mode:
		_remote_spawn = MOTION_REMOTE_SPAWN
	_deadline_ms = Time.get_ticks_msec() + int(max_wait * 1000.0)
	_log("starting match host fixture (max-wait=%.1fs)" % max_wait)
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
	_control.client_done_received.connect(_on_client_done_received)

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
	_session.player_joined.connect(_on_player_joined)
	_session.command_result.connect(_on_command_result)

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
	var host_id := String(host_identity.get("player_id", ""))
	if host_id.is_empty() or not _bridge.bind_actor(StringName(host_id), _host_actor, true):
		_error = "host actor binding failed"
		_fail_early(1)
		return
	_log("host actor %s bound at %s" % [host_id, _host_spawn])

	_write_json(_ready_path, {
		"ok": true,
		"port": _session.get_port(),
		"epoch": _session.get_match_epoch(),
		"pid": OS.get_process_id(),
		"host_player_id": host_id,
	})
	_log("listening on ephemeral port %d epoch %d" % [_session.get_port(), _session.get_match_epoch()])
	await _run_session()

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
	while Time.get_ticks_msec() < _deadline_ms:
		var now := Time.get_ticks_msec()
		if _scenario_start_ms < 0 and not _remote_id.is_empty():
			_scenario_start_ms = now
			_next_move_ms = now
			_log("scenario started for remote player %s" % _remote_id)
		if _scenario_start_ms >= 0:
			_tick_scenario(now)
		if _client_done:
			break
		await create_timer(0.01).timeout
	var ok := true
	if _remote_id.is_empty():
		_error = "host timed out waiting for a client player"
		ok = false
	elif not _target_sent:
		_error = "host never announced a final target tick"
		ok = false
	elif not _client_done:
		_error = "host timed out waiting for the client replica result"
		ok = false
	if not _error.is_empty():
		_exit_code = 1
	ok = ok and _error.is_empty()
	_write_result(ok)
	if _client_done and _client_peer_id > 0:
		var ack_error: int = _control.acknowledge_finish(_client_peer_id)
		_log("finish acknowledgement: %s" % ("sent" if ack_error == OK else "error %d" % ack_error))
		await _wait_for_client_disconnect()
	_log("finishing: ok=%s error=%s steps=%d snapshots=%d" % [
		ok,
		_error,
		_bridge.get_authority_step_count(),
		_bridge.get_snapshot_send_count(),
	])
	_session.stop()
	quit(_exit_code)

func _tick_scenario(now: int) -> void:
	var elapsed := now - _scenario_start_ms
	if _motion_mode:
		_tick_motion_scenario(elapsed)
		return
	if elapsed <= 900:
		if now >= _next_move_ms:
			_send_host_command({"type": "move", "direction": Vector2.RIGHT})
			_next_move_ms = now + 40
		if not _jump_sent and elapsed >= 120:
			_jump_sent = true
			_send_host_command({"type": "jump"})
		if not _dash_sent and elapsed >= 350:
			_dash_sent = true
			_send_host_command({"type": "dash", "direction": Vector2.RIGHT})
	elif not _stop_sent:
		_stop_sent = true
		_send_host_command({"type": "move", "direction": Vector2.ZERO})
	if elapsed >= 1400 and not _remote_killed:
		_remote_killed = true
		_remote_actor.force_dead()
		_log("forced authoritative remote player dead for state convergence")
	if elapsed >= 2200 and not _target_sent:
		_target_tick = _authority.get_tick()
		var target_error: int = _control.announce_target_tick(_client_peer_id, _target_tick)
		_target_sent = target_error == OK
		_log("target tick %d announced to peer %d: %s" % [_target_tick, _client_peer_id, "ok" if _target_sent else "error %d" % target_error])

## Presentation scenario: the host holds still after a short authoritative move
## so the client can prove prediction, interpolation and error convergence on a
## stable final authority state. No fixture actor is killed in this mode.
func _tick_motion_scenario(elapsed: int) -> void:
	var now := Time.get_ticks_msec()
	if elapsed <= 500:
		if now >= _next_move_ms:
			_send_host_command({"type": "move", "direction": Vector2.RIGHT})
			_next_move_ms = now + 40
	elif not _stop_sent:
		_stop_sent = true
		_send_host_command({"type": "move", "direction": Vector2.ZERO})
	if elapsed >= MOTION_TARGET_MS and not _target_sent:
		_target_tick = _authority.get_tick()
		var target_error: int = _control.announce_target_tick(_client_peer_id, _target_tick)
		_target_sent = target_error == OK
		_log("motion target tick %d announced to peer %d: %s" % [_target_tick, _client_peer_id, "ok" if _target_sent else "error %d" % target_error])

func _send_host_command(command: Dictionary) -> void:
	var sequence: int = _bridge.submit_command(command)
	if sequence > 0:
		_host_commands_sent += 1

func _on_player_joined(peer_id: int, player_id: String) -> void:
	if peer_id <= 1 or _client_peer_id > 0:
		return
	if not _bridge.bind_actor(StringName(player_id), _remote_actor, false):
		_error = "remote actor binding failed for " + player_id
		_log(_error)
		return
	_client_peer_id = peer_id
	_remote_id = player_id
	_log("remote peer %d bound to %s at %s" % [peer_id, player_id, _remote_spawn])

func _on_command_result(result: Dictionary) -> void:
	if not bool(result.get("accepted", false)):
		return
	var actual := String(result.get("player_id", ""))
	var claimed := String(result.get("claimed_player_id", ""))
	if claimed.is_empty() or claimed == actual:
		return
	var command: Dictionary = result.get("command", {})
	_forged_claims.append({
		"actual_player_id": actual,
		"claimed_player_id": claimed,
		"command_type": String(command.get("type", "")),
		"sequence": int(result.get("sequence", -1)),
	})
	_log("forged claim recorded: actual=%s claimed=%s" % [actual, claimed])

func _on_client_done_received(tick: int) -> void:
	if _client_done:
		return
	_client_done = true
	_client_done_tick = tick
	_log("client replica done at tick %d" % tick)

func _wait_for_client_disconnect() -> void:
	var deadline := Time.get_ticks_msec() + 2500
	while Time.get_ticks_msec() < deadline:
		if _session.get_player_count() < 2:
			return
		await create_timer(0.02).timeout

func _write_result(ok: bool) -> void:
	var host_identity: Dictionary = _session.get_local_identity()
	var host_id := String(host_identity.get("player_id", ""))
	var remote_identity: Dictionary = _session.get_identity_for_peer(_client_peer_id) if _client_peer_id > 0 else {}
	var host_final: Dictionary = _authority.get_snapshot(StringName(host_id)) if _authority != null and not host_id.is_empty() else {}
	var remote_final: Dictionary = _authority.get_snapshot(StringName(_remote_id)) if _authority != null and not _remote_id.is_empty() else {}
	var command_counts: Dictionary = _bridge.get_command_counts() if _bridge != null else {}
	var last_batch: Dictionary = _bridge.get_last_snapshot_batch() if _bridge != null else {}
	var data := {
		"ok": ok,
		"error": _error,
		"port": _session.get_port(),
		"match_epoch": _session.get_match_epoch(),
		"local_identity": host_identity,
		"host_identity": host_identity,
		"host_player_id": host_id,
		"remote_identity": remote_identity,
		"remote_player_id": _remote_id,
		"client_peer_id": _client_peer_id,
		"host_spawn": _host_spawn,
		"remote_spawn": _remote_spawn,
		"host_initial_position": _vector_json(_host_spawn),
		"remote_initial_position": _vector_json(_remote_spawn),
		"host_final": _state_json(host_final),
		"remote_final": _state_json(remote_final),
		"host_final_ack_sequence": int(host_final.get("ack_sequence", -1)),
		"remote_final_ack_sequence": int(remote_final.get("ack_sequence", -1)),
		"last_batch": _batch_json(last_batch),
		"motion_mode": _motion_mode,
		"target_tick": _target_tick,
		"target_sent": _target_sent,
		"client_done": _client_done,
		"client_done_tick": _client_done_tick,
		"host_commands_sent": _host_commands_sent,
		"submitted_commands": _bridge.get_submitted_command_count() if _bridge != null else 0,
		"consumed_commands": _bridge.get_consumed_command_count() if _bridge != null else 0,
		"command_counts": command_counts,
		"forged_claims": _forged_claims,
		"authority_steps": _bridge.get_authority_step_count() if _bridge != null else 0,
		"physics_frames": _bridge.get_physics_frame_count() if _bridge != null else 0,
		"snapshots_sent": _bridge.get_snapshot_send_count() if _bridge != null else 0,
		"last_snapshot_tick": _bridge.get_last_snapshot_tick() if _bridge != null else -1,
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
