extends SceneTree

## Real Godot late-joining client process for Ticket 02B2A. It joins a host that
## has already advanced, configures the bridge before identity/baseline traffic
## can be lost, applies the reliable full baseline, then proves duplicate and
## older baselines are rejected without changing the replica. It reports the
## first strictly higher snapshot to the host, and after the host closes it
## records the explicit non-combat state and that its replica is frozen.

const SESSION_PATH := "res://scene/script/network/network_session.gd"
const BRIDGE_PATH := "res://scene/script/network/match_network_bridge.gd"
const CONTROL_PATH := "res://tests/fixtures/network_late_join_control.gd"
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
var _local_id := ""
var _baseline: Dictionary = {}
var _baseline_tick := -1
var _duplicate_result: Dictionary = {}
var _stale_result: Dictionary = {}
var _baseline_state_stable := false
var _higher_tick_observed := false
var _progress_sent := false
var _progress_sent_ms := -1
var _close_observed := false
var _close_observed_ms := -1
var _replica_tick_at_close := -1
var _replica_tick_after_wait := -1
var _states_at_close: Dictionary = {}
var _replica_states_stable := false
var _submit_after_close := 0
var _post_close_result: Dictionary = {}
var _presentation_error_before_close := -1.0
var _presentation_render_states_after_close := -1
var _presentation_pending_after_close := -1
var _presentation_ready_after_close := true
var _presentation_fallback_after_close := ""
var _actor_authority_error_after_close := -1.0
var _error := ""

func _initialize() -> void:
	_run.call_deferred()

func _run() -> void:
	var args := _parse_args(OS.get_cmdline_user_args())
	_out_path = String(args.get("out", ""))
	_log_path = String(args.get("log", ""))
	var port := int(args.get("port", "0"))
	var epoch := int(args.get("epoch", "525252"))
	var max_wait := float(args.get("max-wait", "22"))
	_deadline_ms = Time.get_ticks_msec() + int(max_wait * 1000.0)
	_log("starting late-join client fixture (port=%d epoch=%d max-wait=%.1fs)" % [port, epoch, max_wait])
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

	_session = session_script.new()
	_session.name = "NetworkSession"
	root.add_child(_session)
	var join_error: int = _session.join("127.0.0.1", port)
	if join_error != OK:
		_error = "join failed with error %d" % join_error
		_finish(1)
		return

	# Configure before waiting for identity so no reliable baseline can be lost
	# between the join handshake and bridge wiring.
	_bridge = bridge_script.new()
	_bridge.name = "MatchNetworkBridge"
	root.add_child(_bridge)
	if not _bridge.configure(_session):
		_error = "bridge configuration failed"
		_finish(1)
		return
	_session.session_closed.connect(_on_session_closed)

	if not await _wait_for_identity():
		_error = "client did not receive an identity"
		_finish(1)
		return
	_initial_identity = _session.get_local_identity()
	_local_id = String(_initial_identity.get("player_id", ""))
	_log("identity assigned: %s" % JSON.stringify(_initial_identity))

	_local_actor = actor_scene.instantiate()
	_local_actor.global_position = REMOTE_SPAWN
	_local_actor.name = "LocalReplica"
	root.add_child(_local_actor)
	await process_frame
	if _local_id.is_empty() or not _bridge.bind_actor(StringName(_local_id), _local_actor, true):
		_error = "local replica binding failed"
		_finish(1)
		return
	_log("local replica %s bound at %s" % [_local_id, _local_actor.global_position])

	if not await _wait_for_baseline():
		if _error.is_empty():
			_error = "client did not apply a reliable baseline"
		_finish(1)
		return
	_baseline = _bridge.get_last_baseline()
	_baseline_tick = int(_baseline.get("baseline_tick", _baseline.get("server_tick", -1)))
	_log("baseline applied at tick %d with %d players" % [_baseline_tick, (_baseline.get("players", {}) as Dictionary).size()])

	_probe_baseline_rejections()
	if not await _wait_for_higher_tick():
		if _error.is_empty():
			_error = "client never observed a snapshot above the baseline tick"
		_finish(1)
		return
	_higher_tick_observed = true
	_log("observed higher snapshot tick %d (baseline %d)" % [_bridge.get_last_snapshot_tick(), _baseline_tick])

	_progress_sent_ms = Time.get_ticks_msec()
	_progress_sent = _control.report_join_progress({
		"baseline_tick": _baseline_tick,
		"last_snapshot_tick": _bridge.get_last_snapshot_tick(),
		"applied_snapshots": _bridge.get_applied_snapshot_count(),
		"player_id": _local_id,
	}) == OK
	if not _progress_sent:
		_error = "client could not report post-baseline progress"
		_finish(1)
		return

	# Deliberately leave a stale predicted presentation offset before the host
	# closes, so the post-close assertions prove it is discarded and the actor
	# falls back to the last authoritative replica instead of freezing.
	var authoritative_before_close := _replica_position(_local_id)
	var injection_accepted: bool = _bridge.inject_prediction_error(Vector2(20.0, 0.0))
	_presentation_error_before_close = _bridge.get_render_position(StringName(_local_id)).distance_to(authoritative_before_close)
	_log("presentation probe before close: injected=%s error=%.2f" % [injection_accepted, _presentation_error_before_close])

	if not await _wait_for_close():
		if _error.is_empty():
			_error = "client did not observe the host close in bounded time"
		_finish(1)
		return
	await _capture_post_close_state()
	_finish(0)

func _probe_baseline_rejections() -> void:
	if _baseline.is_empty():
		return
	var before_states := _states_json(_bridge.get_replica_states())
	var before_tick := int(_bridge.get_last_snapshot_tick())
	_duplicate_result = _bridge.apply_baseline(_baseline)
	var stale: Dictionary = _baseline.duplicate(true)
	var stale_tick := maxi(_baseline_tick - 1, 0)
	stale["baseline_tick"] = stale_tick
	stale["server_tick"] = stale_tick
	_stale_result = _bridge.apply_baseline(stale)
	var after_states := _states_json(_bridge.get_replica_states())
	_baseline_state_stable = before_tick == int(_bridge.get_last_snapshot_tick()) \
		and JSON.stringify(before_states) == JSON.stringify(after_states)
	_log("baseline rejection probes: duplicate=%s stale=%s stable=%s" % [
		String(_duplicate_result.get("reason", "")),
		String(_stale_result.get("reason", "")),
		_baseline_state_stable,
	])

func _wait_for_identity() -> bool:
	while Time.get_ticks_msec() < _deadline_ms:
		if not _session.get_local_identity().is_empty():
			return true
		if not _session.is_active():
			return false
		await create_timer(0.02).timeout
	return false

func _wait_for_baseline() -> bool:
	while Time.get_ticks_msec() < _deadline_ms:
		if _bridge.has_baseline():
			return true
		if _close_observed or not _session.is_active():
			return false
		await create_timer(0.01).timeout
	return false

func _wait_for_higher_tick() -> bool:
	while Time.get_ticks_msec() < _deadline_ms:
		if int(_bridge.get_last_snapshot_tick()) > _baseline_tick and _bridge.get_applied_snapshot_count() > 0:
			return true
		if _close_observed or not _session.is_active():
			return false
		await create_timer(0.01).timeout
	return false

func _wait_for_close() -> bool:
	while Time.get_ticks_msec() < _deadline_ms:
		if _close_observed:
			return true
		await create_timer(0.01).timeout
	return false

func _on_session_closed() -> void:
	if _close_observed:
		return
	_close_observed = true
	_close_observed_ms = Time.get_ticks_msec()
	_log("session_closed observed")

func _capture_post_close_state() -> void:
	var elapsed := _close_observed_ms - _progress_sent_ms if _progress_sent_ms > 0 else -1
	_replica_tick_at_close = int(_bridge.get_last_snapshot_tick())
	_states_at_close = _states_json(_bridge.get_replica_states())
	_presentation_render_states_after_close = _bridge.get_render_states().size()
	_presentation_pending_after_close = _bridge.get_pending_input_count()
	_presentation_ready_after_close = bool(_bridge.get_client_prediction().get("ready", true))
	_presentation_fallback_after_close = String(_bridge.get_client_prediction().get("last_fallback_reason", ""))
	_actor_authority_error_after_close = _local_actor.global_position.distance_to(_replica_position(_local_id))
	_submit_after_close = _bridge.submit_command({"type": "move", "direction": Vector2.RIGHT})
	var future_tick := maxi(_replica_tick_at_close, _baseline_tick) + 100
	_post_close_result = _bridge.apply_snapshot_batch({
		"match_epoch": int(_initial_identity.get("match_epoch", 0)),
		"server_tick": future_tick,
		"players": {
			_local_id: {
				"player_id": _local_id,
				"tick": future_tick,
				"revision": 9999,
				"position": Vector2(9999.0, 9999.0),
				"velocity": Vector2.ZERO,
				"dead": false,
				"health": 150.0,
				"max_health": 150.0,
			},
		},
	})
	# Give any late unreliable packet a chance to (incorrectly) mutate the replica.
	await create_timer(0.4).timeout
	_replica_tick_after_wait = int(_bridge.get_last_snapshot_tick())
	var after_states := _states_json(_bridge.get_replica_states())
	_replica_states_stable = _replica_tick_at_close == _replica_tick_after_wait \
		and JSON.stringify(_states_at_close) == JSON.stringify(after_states)
	_log("post-close: session_active=%s can_submit=%s combat=%s closed=%s replica_active=%s submit=%d post_snapshot=%s stable=%s elapsed=%dms" % [
		_session.is_active(),
		_bridge.can_submit_command(),
		_bridge.is_combat_active(),
		_bridge.is_session_closed(),
		_bridge.replica.get_active(),
		_submit_after_close,
		String(_post_close_result.get("reason", "")),
		_replica_states_stable,
		elapsed,
	])

func _finish(code: int) -> void:
	if _final_identity.is_empty() and _session != null:
		_final_identity = _session.get_local_identity()
	var elapsed := _close_observed_ms - _progress_sent_ms if _close_observed_ms > 0 and _progress_sent_ms > 0 else -1
	var data := {
		"ok": code == 0 and _error.is_empty(),
		"error": _error,
		"server_port": _session.get_port() if _session != null else 0,
		"initial_identity": _initial_identity,
		"final_identity": _final_identity,
		"baseline": _batch_json(_baseline),
		"baseline_tick": _baseline_tick,
		"baseline_received_count": _session.get_baseline_received_count() if _session != null else 0,
		"baseline_applied_count": _session.get_baseline_applied_count() if _session != null else 0,
		"bridge_baseline_received_count": _bridge.get_baseline_received_count() if _bridge != null else 0,
		"bridge_baseline_applied_count": _bridge.get_baseline_applied_count() if _bridge != null else 0,
		"duplicate_baseline_result": _duplicate_result,
		"stale_baseline_result": _stale_result,
		"baseline_state_stable": _baseline_state_stable,
		"applied_snapshots": _bridge.get_applied_snapshot_count() if _bridge != null else 0,
		"last_snapshot_tick": _bridge.get_last_snapshot_tick() if _bridge != null else -1,
		"higher_tick_observed": _higher_tick_observed,
		"progress_sent": _progress_sent,
		"close_observed": _close_observed,
		"close_elapsed_ms": elapsed,
		"session_active_after_close": _session.is_active() if _session != null else false,
		"bridge_can_submit_after_close": _bridge.can_submit_command() if _bridge != null else false,
		"bridge_combat_active_after_close": _bridge.is_combat_active() if _bridge != null else false,
		"bridge_session_closed": _bridge.is_session_closed() if _bridge != null else false,
		"replica_active_after_close": _bridge.replica.get_active() if _bridge != null and _bridge.replica != null else false,
		"replica_tick_at_close": _replica_tick_at_close,
		"replica_tick_after_wait": _replica_tick_after_wait,
		"replica_states_stable": _replica_states_stable,
		"submit_after_close_sequence": _submit_after_close,
		"post_close_snapshot_reason": String(_post_close_result.get("reason", "")),
		"presentation_error_before_close": _presentation_error_before_close,
		"presentation_render_states_after_close": _presentation_render_states_after_close,
		"presentation_pending_after_close": _presentation_pending_after_close,
		"presentation_ready_after_close": _presentation_ready_after_close,
		"presentation_fallback_after_close": _presentation_fallback_after_close,
		"actor_authority_error_after_close": _actor_authority_error_after_close,
		"last_rejection": _bridge.get_last_rejection() if _bridge != null else {},
		"pid": OS.get_process_id(),
	}
	_log("finishing: ok=%s error=%s snapshots=%d baseline_tick=%d" % [
		code == 0 and _error.is_empty(),
		_error,
		int(data["applied_snapshots"]),
		_baseline_tick,
	])
	_write_json(_out_path, data)
	if _session != null:
		_session.stop()
	quit(code)

func _states_json(states: Dictionary) -> Dictionary:
	var result: Dictionary = {}
	for player_id: Variant in states:
		result[String(player_id)] = _state_json(states[player_id])
	return result

func _replica_position(player_id: String) -> Vector2:
	if _bridge == null or player_id.is_empty():
		return Vector2.ZERO
	var state: Dictionary = _bridge.get_replica_state(StringName(player_id))
	var value: Variant = state.get("position", Vector2.ZERO)
	return value if value is Vector2 else Vector2.ZERO

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
		"baseline_tick": int(batch.get("baseline_tick", batch.get("server_tick", -1))),
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
