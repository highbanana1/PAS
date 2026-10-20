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
const MOTION_REMOTE_SPAWN := Vector2(620.0, 150.0)
const MOTION_STOP_MS := 700
const MOTION_INJECT_MS := 1200
const INJECTED_ERROR := Vector2(20.0, 0.0)
const LOCAL_CONVERGENCE_TOLERANCE := 0.5

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
var _motion_mode := false
var _probe_attempts := 0
var _prediction_observable := false
var _probe_data: Dictionary = {}
var _observable_probe: Dictionary = {}
var _injection_done := false
var _injection_accepted := false
var _injection_ms := -1
var _post_injection_error := -1.0
var _converged_error := -1.0
var _convergence_ms := -1
var _has_remote_render := false
var _last_remote_render := Vector2.ZERO
var _has_remote_authority := false
var _last_remote_authority := Vector2.ZERO
var _remote_max_render_step := 0.0
var _max_snapshot_step := 0.0
var _remote_off_authority_frames := 0
var _remote_min_samples := 999
var _local_final_render := Vector2.ZERO
var _local_final_error := -1.0
var _remote_final_render := Vector2.ZERO
var _remote_final_error := -1.0
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
	_motion_mode = String(args.get("motion", "0")) == "1"
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
	_local_actor.global_position = MOTION_REMOTE_SPAWN if _motion_mode else REMOTE_SPAWN
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
		if _motion_mode and _scenario_start_ms >= 0 and not _prediction_observable and _probe_attempts < 4:
			_probe_local_prediction()
		if _scenario_start_ms >= 0:
			_tick_scenario(now)
			_track_motion_stats()
			_track_motion_error(now)
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
	if _motion_mode:
		_tick_motion_scenario(now, elapsed)
		return
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

## Presentation scenario: local movement (predicted), a deliberate small
## prediction error, and a stable authority tail so both local and remote
## presentation can be compared with the host's final authoritative state.
func _tick_motion_scenario(now: int, elapsed: int) -> void:
	if elapsed <= MOTION_STOP_MS:
		if now >= _next_move_ms:
			_send_command({"type": "move", "direction": Vector2.LEFT})
			_next_move_ms = now + 50
	elif not _stop_sent:
		_stop_sent = true
		_send_command({"type": "move", "direction": Vector2.ZERO})
	if elapsed >= MOTION_INJECT_MS and not _injection_done:
		_injection_done = true
		_injection_ms = now
		var local_id := _local_player_id()
		var auth := _replica_position(local_id)
		var before: Vector2 = _bridge.get_render_position(StringName(local_id))
		_injection_accepted = bool(_bridge.inject_prediction_error(INJECTED_ERROR))
		var after: Vector2 = _bridge.get_render_position(StringName(local_id))
		_post_injection_error = after.distance_to(auth)
		_log("injected prediction error accepted=%s before=%.2f after=%.2f auth=%s render=%s" % [
			_injection_accepted,
			before.distance_to(auth),
			_post_injection_error,
			str(auth),
			str(after),
		])

func _probe_local_prediction() -> void:
	_probe_attempts += 1
	var local_id := _local_player_id()
	if local_id.is_empty():
		return
	var before_applied := int(_bridge.get_applied_snapshot_count())
	var before_tick := int(_bridge.get_last_snapshot_tick())
	var before_render: Vector2 = _bridge.get_render_position(StringName(local_id))
	var before_auth := _replica_position(local_id)
	var sequence := _send_command({"type": "move", "direction": Vector2.LEFT})
	var after_render: Vector2 = _bridge.get_render_position(StringName(local_id))
	var after_applied := int(_bridge.get_applied_snapshot_count())
	var after_tick := int(_bridge.get_last_snapshot_tick())
	var pending := int(_bridge.get_pending_input_count())
	var moved: float = before_render.distance_to(after_render)
	var probe := {
		"sequence": sequence,
		"moved": moved,
		"before_render": _vector_json(before_render),
		"after_render": _vector_json(after_render),
		"before_authoritative": _vector_json(before_auth),
		"before_applied_snapshots": before_applied,
		"after_applied_snapshots": after_applied,
		"before_snapshot_tick": before_tick,
		"after_snapshot_tick": after_tick,
		"pending_inputs": pending,
	}
	_probe_data = probe
	if sequence > 0 and moved > 0.5 and after_applied == before_applied \
			and after_tick == before_tick and pending >= 1:
		_prediction_observable = true
		_observable_probe = probe.duplicate(true)
		_log("prediction observable before any newer snapshot: moved=%.3f pending=%d tick=%d" % [moved, pending, before_tick])

func _track_motion_stats() -> void:
	if not _motion_mode or _scenario_start_ms < 0:
		return
	var remote_id := _other_player_id()
	if remote_id.is_empty():
		return
	var sample_count := int(_bridge.get_remote_sample_count(StringName(remote_id)))
	if sample_count > 0:
		_remote_min_samples = mini(_remote_min_samples, sample_count)
	if sample_count <= 0:
		return
	var render: Vector2 = _bridge.get_render_position(StringName(remote_id))
	var authority_state: Dictionary = _bridge.get_replica_state(StringName(remote_id))
	if authority_state.is_empty():
		return
	var authority_position := _state_position(authority_state)
	if _has_remote_authority and not authority_position.is_equal_approx(_last_remote_authority):
		_max_snapshot_step = maxf(_max_snapshot_step, authority_position.distance_to(_last_remote_authority))
	_last_remote_authority = authority_position
	_has_remote_authority = true
	if render.distance_to(authority_position) > 0.1:
		_remote_off_authority_frames += 1
	if _has_remote_render:
		_remote_max_render_step = maxf(_remote_max_render_step, render.distance_to(_last_remote_render))
	_last_remote_render = render
	_has_remote_render = true

func _track_motion_error(now: int) -> void:
	if not _motion_mode or not _injection_done:
		return
	var local_id := _local_player_id()
	var authoritative := _replica_position(local_id)
	var render: Vector2 = _bridge.get_render_position(StringName(local_id))
	var error: float = render.distance_to(authoritative)
	if _post_injection_error < 0.0:
		_post_injection_error = error
	if _converged_error < 0.0 and error <= LOCAL_CONVERGENCE_TOLERANCE:
		_converged_error = error
		_convergence_ms = now - _injection_ms
		_log("prediction error converged in %d ms (error=%.3f)" % [_convergence_ms, _converged_error])

func _local_player_id() -> String:
	return String(_initial_identity.get("player_id", ""))

func _replica_position(player_id: String) -> Vector2:
	return _state_position(_bridge.get_replica_state(StringName(player_id)))

func _state_position(state: Dictionary) -> Vector2:
	var value: Variant = state.get("position", Vector2.ZERO)
	return value if value is Vector2 else Vector2.ZERO

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
	if _motion_mode:
		var local_id := _local_player_id()
		var local_authoritative := _replica_position(local_id)
		_local_final_render = _bridge.get_render_position(StringName(local_id))
		_local_final_error = _local_final_render.distance_to(local_authoritative)
		var remote_id := _other_player_id()
		if not remote_id.is_empty():
			var remote_authoritative := _replica_position(remote_id)
			_remote_final_render = _bridge.get_render_position(StringName(remote_id))
			_remote_final_error = _remote_final_render.distance_to(remote_authoritative)
		if _converged_error < 0.0 and _local_final_error <= LOCAL_CONVERGENCE_TOLERANCE:
			_converged_error = _local_final_error
		_log("final presentation: local_error=%.3f remote_error=%.3f" % [_local_final_error, _remote_final_error])
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
		"motion_mode": _motion_mode,
		"prediction_observable": _prediction_observable,
		"prediction_attempts": _probe_attempts,
		"prediction_probe": _observable_probe if not _observable_probe.is_empty() else _probe_data,
		"pending_inputs_at_finish": _bridge.get_pending_input_count() if _bridge != null else 0,
		"client_prediction": _bridge.get_client_prediction() if _bridge != null else {},
		"client_has_authority": _bridge.get_authority() != null if _bridge != null else false,
		"client_is_host_authority": _bridge.is_host_authority() if _bridge != null else true,
		"injection_done": _injection_done,
		"injection_accepted": _injection_accepted,
		"post_injection_error": _post_injection_error,
		"converged_error": _converged_error,
		"convergence_ms": _convergence_ms,
		"remote_min_samples": _remote_min_samples,
		"remote_interpolated_frames": _bridge.get_remote_interpolated_frame_count(StringName(_other_player_id())) if _bridge != null else 0,
		"remote_snap_events": _bridge.get_remote_snap_event_count(StringName(_other_player_id())) if _bridge != null else 0,
		"remote_fallback_reason": _bridge.get_remote_fallback_reason(StringName(_other_player_id())) if _bridge != null else "",
		"remote_max_render_step": _remote_max_render_step,
		"max_snapshot_step": _max_snapshot_step,
		"remote_off_authority_frames": _remote_off_authority_frames,
		"local_final_render": _vector_json(_local_final_render),
		"local_final_error": _local_final_error,
		"remote_final_render": _vector_json(_remote_final_render),
		"remote_final_error": _remote_final_error,
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
			result[key] = _vector_json(value)
	return result

func _vector_json(value: Vector2) -> Dictionary:
	return {"x": value.x, "y": value.y}

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
