extends SceneTree

## Real Godot client process for the Ticket 02B1 test. It joins the host over
## localhost, submits only its own movement envelopes through NetworkSession,
## and applies authoritative snapshot batches received on the
## unreliable_ordered snapshot channel to an observable replica. It also feeds
## two synthetic stale batches through the same replica path to prove that old
## epochs and regressed server ticks are ignored. The reliable fixture control
## only coordinates the target tick and shutdown.

const SESSION_PATH := "res://scene/script/network/network_session.gd"
const BRIDGE_PATH := "res://scene/script/network/match_network_bridge.gd"
const CONTROL_PATH := "res://tests/fixtures/network_match_control.gd"
const ACTOR_SCENE := "res://tests/fixtures/network_match_actor.tscn"
const REMOTE_SPAWN := Vector2(180.0, 150.0)

var _session
var _bridge
var _control
var _local_actor
var _out_path := ""
var _log_path := ""
var _deadline_ms := 0
var _initial_identity: Dictionary = {}
var _final_identity: Dictionary = {}
var _scenario_start_ms := -1
var _next_move_ms := 0
var _jump_sent := false
var _dash_sent := false
var _forged_sent := false
var _stop_sent := false
var _injected_rejections := false
var _target_tick := -1
var _final_captured := false
var _client_done_sent := false
var _finish_acknowledged := false
var _commands_sent := 0
var _final_states: Dictionary = {}
var _last_batch: Dictionary = {}
var _stale_result: Dictionary = {}
var _regressed_result: Dictionary = {}
var _error := ""

func _initialize() -> void:
	_run.call_deferred()

func _run() -> void:
	var args := _parse_args(OS.get_cmdline_user_args())
	_out_path = String(args.get("out", ""))
	_log_path = String(args.get("log", ""))
	var port := int(args.get("port", "0"))
	var epoch := int(args.get("epoch", "424242"))
	var max_wait := float(args.get("max-wait", "18"))
	_deadline_ms = Time.get_ticks_msec() + int(max_wait * 1000.0)
	_log("starting match client fixture (port=%d max-wait=%.1fs)" % [port, max_wait])
	if _out_path.is_empty() or port <= 0:
		_error = "missing --out/--port"
		_finish(1)
		return

	var control_script = load(CONTROL_PATH)
	var session_script = load(SESSION_PATH)
	var bridge_script = load(BRIDGE_PATH)
	var actor_scene = load(ACTOR_SCENE)
	if control_script == null or session_script == null or bridge_script == null or actor_scene == null:
		_error = "a required client fixture module is missing"
		_finish(1)
		return
	if not control_script.can_instantiate() or not session_script.can_instantiate() or not bridge_script.can_instantiate():
		_error = "a required client fixture module cannot instantiate"
		_finish(1)
		return

	_control = control_script.new()
	_control.name = "FixtureControl"
	_control.log_path = _log_path
	root.add_child(_control)
	_control.target_tick_announced.connect(_on_target_tick_announced)
	_control.finish_acknowledged.connect(_on_finish_acknowledged)

	_session = session_script.new()
	_session.name = "NetworkSession"
	root.add_child(_session)
	var join_error: int = _session.join("127.0.0.1", port)
	if join_error != OK:
		_error = "join failed with error %d" % join_error
		_finish(1)
		return
	if not await _wait_for_identity():
		_error = "client did not receive an identity"
		_finish(1)
		return
	_initial_identity = _session.get_local_identity()
	_log("identity assigned: %s" % JSON.stringify(_initial_identity))

	_bridge = bridge_script.new()
	_bridge.name = "MatchNetworkBridge"
	root.add_child(_bridge)
	if not _bridge.configure(_session):
		_error = "bridge configuration failed"
		_finish(1)
		return
	_local_actor = actor_scene.instantiate()
	_local_actor.global_position = REMOTE_SPAWN
	_local_actor.name = "LocalReplica"
	root.add_child(_local_actor)
	await process_frame
	var local_id := String(_initial_identity.get("player_id", ""))
	if local_id.is_empty() or not _bridge.bind_actor(StringName(local_id), _local_actor, true):
		_error = "local replica binding failed"
		_finish(1)
		return
	_log("local replica %s bound at %s" % [local_id, _local_actor.global_position])

	await _run_scenario()
	_final_identity = _session.get_local_identity()
	var ok := _error.is_empty() and _final_captured and _client_done_sent and _finish_acknowledged
	if not ok and _error.is_empty():
		_error = "client scenario did not complete"
	_finish(0 if ok else 1)

func _run_scenario() -> void:
	while Time.get_ticks_msec() < _deadline_ms:
		var now := Time.get_ticks_msec()
		var applied := int(_bridge.get_applied_snapshot_count())
		if _scenario_start_ms < 0 and applied > 0:
			_scenario_start_ms = now
			_next_move_ms = now
			_log("scenario started after first authoritative snapshot")
		if _scenario_start_ms >= 0:
			_tick_scenario(now)
			if applied >= 2 and not _injected_rejections:
				_inject_rejections()
		if _target_tick > 0 and not _final_captured and int(_bridge.get_last_snapshot_tick()) >= _target_tick:
			_capture_final()
			_client_done_sent = _control.report_client_done(int(_bridge.get_last_snapshot_tick())) == OK
			if not _client_done_sent:
				_error = "client could not report completion"
			break
		await create_timer(0.01).timeout
	if not _final_captured and _error.is_empty():
		_error = "client timed out before applying a snapshot at the target tick"
	if _client_done_sent:
		await _wait_for_finish_ack()

func _tick_scenario(now: int) -> void:
	var elapsed := now - _scenario_start_ms
	if elapsed <= 700:
		if now >= _next_move_ms:
			_send_command({"type": "move", "direction": Vector2.LEFT})
			_next_move_ms = now + 50
		if not _jump_sent and elapsed >= 180:
			_jump_sent = true
			_send_command({"type": "jump"})
		if not _dash_sent and elapsed >= 380:
			_dash_sent = true
			_send_command({"type": "dash", "direction": Vector2.LEFT})
		if not _forged_sent and elapsed >= 100:
			var other_id := _other_player_id()
			if not other_id.is_empty():
				_forged_sent = true
				_send_command({"type": "move", "direction": Vector2.RIGHT, "player_id": other_id})
				_log("sent forged player_id claim for " + other_id)
	elif not _stop_sent:
		_stop_sent = true
		_send_command({"type": "move", "direction": Vector2.ZERO})

func _send_command(command: Dictionary) -> int:
	var sequence: int = _bridge.submit_command(command)
	if sequence > 0:
		_commands_sent += 1
	else:
		_log("command submission failed for " + String(command.get("type", "")))
	return sequence

func _inject_rejections() -> void:
	var last: Dictionary = _bridge.get_last_applied_batch()
	if last.is_empty():
		return
	_injected_rejections = true
	var last_tick := int(last.get("server_tick", -1))
	var stale_epoch: Dictionary = last.duplicate(true)
	stale_epoch["match_epoch"] = int(last.get("match_epoch", 0)) - 1
	stale_epoch["server_tick"] = last_tick + 5
	_stale_result = _bridge.apply_snapshot_batch(stale_epoch)
	var regressed: Dictionary = last.duplicate(true)
	regressed["server_tick"] = last_tick - 1
	_regressed_result = _bridge.apply_snapshot_batch(regressed)
	_log("replica rejection probes: stale_epoch=%s regressed_tick=%s" % [
		String(_stale_result.get("reason", "")),
		String(_regressed_result.get("reason", "")),
	])

func _other_player_id() -> String:
	var states: Dictionary = _bridge.get_replica_states()
	for player_id: Variant in states.keys():
		var key := String(player_id)
		if key != String(_initial_identity.get("player_id", "")):
			return key
	return ""

func _capture_final() -> void:
	_final_captured = true
	_final_states = _states_json(_bridge.get_replica_states())
	_last_batch = _batch_json(_bridge.get_last_applied_batch())
	_log("captured final replica at tick %d with %d players" % [_bridge.get_last_snapshot_tick(), _final_states.size()])

func _on_target_tick_announced(tick: int) -> void:
	_target_tick = tick
	_log("target tick %d received" % tick)

func _on_finish_acknowledged() -> void:
	_finish_acknowledged = true

func _wait_for_finish_ack() -> void:
	var deadline := Time.get_ticks_msec() + 3000
	while Time.get_ticks_msec() < deadline:
		if _finish_acknowledged:
			_log("reliable finish acknowledgement received")
			return
		await create_timer(0.02).timeout
	if _error.is_empty():
		_error = "client timed out waiting for the finish acknowledgement"

func _wait_for_identity() -> bool:
	while Time.get_ticks_msec() < _deadline_ms:
		var identity: Dictionary = _session.get_local_identity()
		if not identity.is_empty():
			return true
		if not _session.is_active():
			return false
		await create_timer(0.02).timeout
	return false

func _finish(code: int) -> void:
	if _final_identity.is_empty() and _session != null:
		_final_identity = _session.get_local_identity()
	var applied := int(_bridge.get_applied_snapshot_count()) if _bridge != null else 0
	var data := {
		"ok": code == 0 and _error.is_empty(),
		"error": _error,
		"server_port": _session.get_port() if _session != null else 0,
		"initial_identity": _initial_identity,
		"final_identity": _final_identity,
		"applied_snapshots": applied,
		"last_snapshot_tick": _bridge.get_last_snapshot_tick() if _bridge != null else -1,
		"target_tick": _target_tick,
		"stale_epoch_rejections": _bridge.get_rejected_snapshot_count("stale_epoch") if _bridge != null else 0,
		"regressed_tick_rejections": _bridge.get_rejected_snapshot_count("regressed_tick") if _bridge != null else 0,
		"stale_epoch_result": _stale_result,
		"regressed_tick_result": _regressed_result,
		"replica_states": _final_states,
		"last_batch": _last_batch,
		"commands_sent": _commands_sent,
		"final_captured": _final_captured,
		"client_done_sent": _client_done_sent,
		"finish_acknowledged": _finish_acknowledged,
		"pid": OS.get_process_id(),
	}
	_log("finishing: ok=%s error=%s snapshots=%d" % [code == 0 and _error.is_empty(), _error, applied])
	_write_json(_out_path, data)
	if _session != null:
		_session.stop()
	quit(code)

func _states_json(states: Dictionary) -> Dictionary:
	var result: Dictionary = {}
	for player_id: Variant in states:
		result[String(player_id)] = _state_json(states[player_id])
	return result

func _state_json(state: Dictionary) -> Dictionary:
	if state.is_empty():
		return {}
	var result: Dictionary = state.duplicate(true)
	for key in ["position", "velocity"]:
		var value: Variant = result.get(key)
		if value is Vector2:
			result[key] = {"x": value.x, "y": value.y}
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

func _parse_args(args: PackedStringArray) -> Dictionary:
	var result: Dictionary = {}
	for raw: String in args:
		var text := raw.trim_prefix("--")
		var split := text.split("=", true, 1)
		if split.size() == 2:
			result[split[0]] = split[1]
	return result

func _log(message: String) -> void:
	var line := "[%d] CLIENT %s" % [Time.get_ticks_msec(), message]
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
