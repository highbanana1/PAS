extends SceneTree

## Ticket 02B2A behavior test. It first proves the replica contract directly:
## snapshots before a baseline cannot pollute state, a baseline is applied once,
## duplicate/old baselines are idempotently rejected and later batches must
## advance strictly. Then it launches two real Godot ENet processes: the host
## advances its authority before any client exists, a client late-joins and
## receives a reliable full baseline for that exact authority tick, then keeps
## receiving strictly higher unreliable snapshot ticks. Finally the host closes
## and the client must enter an explicit non-combat state within a bounded time.

const SESSION_PATH := "res://scene/script/network/network_session.gd"
const BRIDGE_PATH := "res://scene/script/network/match_network_bridge.gd"
const REPLICA_PATH := "res://scene/script/network/snapshot_replica.gd"
const HOST_FIXTURE := "res://tests/fixtures/network_late_join_host.gd"
const CLIENT_FIXTURE := "res://tests/fixtures/network_late_join_client.gd"
const MATCH_EPOCH := 525252
const FIXTURE_MAX_WAIT_SECONDS := 22
const HOST_TIMEOUT_MS := 30000
const CLIENT_TIMEOUT_MS := 30000
const EXIT_TIMEOUT_MS := 10000
const POSITION_TOLERANCE := 0.25
const CLOSE_BOUND_MS := 8000
const HOST_LOG := "host_fixture.log"
const CLIENT_LOG := "client_fixture.log"

var failures: Array[String] = []
var host_pid: int = -1
var client_pid: int = -1
var artifact_dir_abs: String = ""
var host_ready: Dictionary = {}

func _initialize() -> void:
	_run.call_deferred()

func check(ok: bool, label: String) -> void:
	print(("PASS: " if ok else "FAIL: ") + label)
	if not ok:
		failures.append(label)

func _finish() -> void:
	print("RESULT: ", failures.size(), " failures")
	quit(0 if failures.is_empty() else 1)

func _run() -> void:
	print("TEST: reliable late-join baseline, snapshot continuity and host-disconnect shutdown")
	artifact_dir_abs = OS.get_temp_dir().path_join("pas-ticket02b2a-%d" % OS.get_process_id())
	DirAccess.make_dir_recursive_absolute(artifact_dir_abs)
	for file_name in ["host_ready.json", "host_result.json", "client_result.json", HOST_LOG, CLIENT_LOG]:
		_remove_if_present(_path(file_name))

	var session_script = load(SESSION_PATH)
	var bridge_script = load(BRIDGE_PATH)
	var replica_script = load(REPLICA_PATH)
	check(session_script != null and session_script.can_instantiate(), "NetworkSession exposes a loadable public module")
	check(bridge_script != null and bridge_script.can_instantiate(), "MatchNetworkBridge exposes a loadable public module")
	check(replica_script != null and replica_script.can_instantiate(), "SnapshotReplica exposes a loadable public module")
	if session_script == null or not session_script.can_instantiate() \
			or bridge_script == null or not bridge_script.can_instantiate() \
			or replica_script == null or not replica_script.can_instantiate():
		_finish()
		return

	_check_baseline_contract(session_script, bridge_script, replica_script)
	_test_replica_baseline_gating(replica_script)
	var port := await _launch_and_wait_for_host()
	if port <= 0:
		_kill_children()
		_finish()
		return
	_launch_client(port)
	await _collect_results(port)
	_kill_children()
	_finish()

func _has_method(script: Script, method_name: String) -> bool:
	for method: Dictionary in script.get_script_method_list():
		if String(method.get("name", "")) == method_name:
			return true
	return false

func _has_signal(script: Script, signal_name: String) -> bool:
	for signal_info: Dictionary in script.get_script_signal_list():
		if String(signal_info.get("name", "")) == signal_name:
			return true
	return false

func _constant(script: Script, name: String) -> String:
	var constants: Dictionary = script.get_script_constant_map()
	return String(constants.get(name, ""))

func _check_baseline_contract(session_script: Script, bridge_script: Script, replica_script: Script) -> void:
	check(_has_method(session_script, "send_baseline"), "NetworkSession owns reliable baseline delivery")
	check(_has_signal(session_script, "baseline_received"), "NetworkSession exposes baseline_received")
	check(_has_signal(session_script, "baseline_applied"), "NetworkSession exposes baseline_applied")
	check(_has_method(session_script, "mark_baseline_applied"), "NetworkSession records the applied baseline")
	check(_has_method(bridge_script, "apply_baseline"), "MatchNetworkBridge applies a received baseline")
	check(_has_method(bridge_script, "can_submit_command"), "MatchNetworkBridge exposes command eligibility")
	check(_has_method(bridge_script, "is_combat_active"), "MatchNetworkBridge exposes its combat state")
	check(_has_method(bridge_script, "is_session_closed"), "MatchNetworkBridge exposes its closed state")
	check(_has_signal(bridge_script, "baseline_received"), "MatchNetworkBridge exposes baseline_received")
	check(_has_signal(bridge_script, "baseline_applied"), "MatchNetworkBridge exposes baseline_applied")
	check(_has_signal(bridge_script, "session_closed"), "MatchNetworkBridge exposes session_closed")
	check(_constant(replica_script, "REJECT_BASELINE_REQUIRED") == "baseline_required", "Replica names the missing-baseline rejection")
	check(_constant(replica_script, "REJECT_DUPLICATE_BASELINE") == "duplicate_baseline", "Replica names the duplicate-baseline rejection")
	check(_constant(replica_script, "REJECT_STALE_BASELINE") == "stale_baseline", "Replica names the old-baseline rejection")
	check(_constant(replica_script, "REJECT_NOT_ACTIVE") == "not_active", "Replica names the inactive rejection")

func _test_replica_baseline_gating(replica_script: Script) -> void:
	if not _has_method(replica_script, "apply_baseline") or not _has_method(replica_script, "deactivate"):
		check(false, "SnapshotReplica exposes the baseline gating interface")
		return
	var replica = replica_script.new()
	replica.configure(MATCH_EPOCH)
	check(bool(replica.get_active()), "A configured replica is active")

	var early: Dictionary = replica.apply_batch(_snapshot_batch(MATCH_EPOCH, 77, "player_2", Vector2(777.0, 777.0), Vector2.ZERO, 4))
	check(String(early.get("reason", "")) == "baseline_required", "A snapshot that arrives before the baseline is rejected")
	check(int(replica.get_last_tick()) == -1, "A pre-baseline snapshot does not advance the replica tick")
	check(replica.get_states().is_empty(), "A pre-baseline snapshot does not populate replica state")
	check(not bool(replica.has_baseline()), "A pre-baseline snapshot does not mark a baseline as applied")

	var baseline := _baseline(MATCH_EPOCH, 10, {
		"player_1": _player_state("player_1", 10, 3, Vector2(40.0, 10.0), Vector2(2.0, 0.0)),
		"player_2": _player_state("player_2", 10, 7, Vector2(90.0, 20.0), Vector2.ZERO),
	})
	var first: Dictionary = replica.apply_baseline(baseline)
	check(bool(first.get("applied", false)), "Replica applies a complete baseline")
	check(bool(replica.has_baseline()), "Replica reports that a baseline has been applied")
	check(int(replica.get_baseline_applied_count()) == 1, "Replica counts one applied baseline")
	check(int(replica.get_last_tick()) == 10, "Replica records the baseline tick")
	var states: Dictionary = replica.get_states()
	check(states.has("player_1") and states.has("player_2"), "Baseline installs every registered player snapshot")
	check(int(states.get("player_2", {}).get("revision", -1)) == 7, "Baseline preserves the per-player revision")

	var duplicate: Dictionary = replica.apply_baseline(baseline)
	check(String(duplicate.get("reason", "")) == "duplicate_baseline", "A duplicate baseline is idempotently rejected")
	var old_baseline := _baseline(MATCH_EPOCH, 9, {
		"player_1": _player_state("player_1", 9, 2, Vector2(999.0, 999.0), Vector2.ZERO),
	})
	var old: Dictionary = replica.apply_baseline(old_baseline)
	check(String(old.get("reason", "")) == "stale_baseline", "An older baseline is idempotently rejected")
	check(int(replica.get_last_tick()) == 10, "Rejected baselines do not change the applied tick")
	check(replica.get_state("player_2").get("position", Vector2.ZERO).is_equal_approx(Vector2(90.0, 20.0)), "Rejected baselines do not rewind replica state")
	check(int(replica.get_baseline_applied_count()) == 1, "Rejected baselines do not count as applied")

	var same_tick: Dictionary = replica.apply_batch(_snapshot_batch(MATCH_EPOCH, 10, "player_2", Vector2(1.0, 1.0), Vector2.ZERO, 8))
	check(String(same_tick.get("reason", "")) == "regressed_tick", "A snapshot at the baseline tick is rejected")
	var higher: Dictionary = replica.apply_batch(_snapshot_batch(MATCH_EPOCH, 11, "player_2", Vector2(91.0, 20.0), Vector2.ZERO, 8))
	check(bool(higher.get("applied", false)), "A snapshot strictly above the baseline tick is accepted")
	check(int(replica.get_last_tick()) == 11, "An accepted snapshot advances the replica tick")
	var regressed: Dictionary = replica.apply_batch(_snapshot_batch(MATCH_EPOCH, 10, "player_2", Vector2(2.0, 2.0), Vector2.ZERO, 9))
	check(String(regressed.get("reason", "")) == "regressed_tick", "A regressed snapshot after the baseline is rejected")
	check(replica.get_state("player_2").get("position", Vector2.ZERO).is_equal_approx(Vector2(91.0, 20.0)), "Regressed snapshots do not move the replica")

	var invalid_replica = replica_script.new()
	invalid_replica.configure(MATCH_EPOCH)
	var invalid: Dictionary = invalid_replica.apply_baseline({
		"match_epoch": MATCH_EPOCH,
		"baseline_tick": 4,
		"server_tick": 4,
		"players": {"player_2": {"player_id": "player_2", "position": Vector2.ZERO, "velocity": Vector2.ZERO}},
	})
	check(String(invalid.get("reason", "")) == "invalid_batch", "A baseline without per-player revisions is rejected")
	check(not bool(invalid_replica.has_baseline()), "An invalid baseline does not mark the replica ready")
	invalid_replica.deactivate()
	var inactive: Dictionary = invalid_replica.apply_batch(_snapshot_batch(MATCH_EPOCH, 5, "player_2", Vector2.ZERO, Vector2.ZERO, 1))
	check(String(inactive.get("reason", "")) == "not_active", "A deactivated replica rejects further snapshots")

func _player_state(player_id: String, tick: int, revision: int, position: Vector2, velocity: Vector2) -> Dictionary:
	return {
		"player_id": player_id,
		"tick": tick,
		"revision": revision,
		"position": position,
		"velocity": velocity,
		"dead": false,
		"health": 150.0,
		"max_health": 150.0,
	}

func _baseline(epoch: int, tick: int, players: Dictionary) -> Dictionary:
	return {
		"match_epoch": epoch,
		"baseline_tick": tick,
		"server_tick": tick,
		"players": players,
	}

func _snapshot_batch(epoch: int, tick: int, player_id: String, position: Vector2, velocity: Vector2, revision: int) -> Dictionary:
	return {
		"match_epoch": epoch,
		"server_tick": tick,
		"players": {
			player_id: _player_state(player_id, tick, revision, position, velocity),
		},
	}

func _launch_and_wait_for_host() -> int:
	var args: PackedStringArray = PackedStringArray([
		"--headless",
		"--path",
		ProjectSettings.globalize_path("res://"),
		"--script",
		HOST_FIXTURE,
		"--",
		"--port=0",
		"--epoch=%d" % MATCH_EPOCH,
		"--ready=" + _path("host_ready.json"),
		"--out=" + _path("host_result.json"),
		"--log=" + _path(HOST_LOG),
		"--max-wait=%d" % FIXTURE_MAX_WAIT_SECONDS,
	])
	host_pid = OS.create_process(OS.get_executable_path(), args, false)
	check(host_pid > 0, "Test fixture starts a real host Godot process")
	if host_pid <= 0:
		return 0
	var ready := await _wait_for_json(_path("host_ready.json"), host_pid, HOST_TIMEOUT_MS)
	check(not ready.is_empty(), "Host process publishes readiness after advancing before any client joins")
	if ready.is_empty():
		_dump_log_tail(_path(HOST_LOG))
		return 0
	host_ready = ready
	check(bool(ready.get("ok", false)), "Host process reports a successful pre-advance and ENet listen")
	var port := int(ready.get("port", 0))
	check(port > 0, "Host readiness carries a positive ephemeral port")
	check(int(ready.get("epoch", -1)) == MATCH_EPOCH, "Host readiness carries the match epoch")
	check(int(ready.get("pre_join_tick", -1)) > 0, "Host authority advanced before the client joined")
	var spawn := _as_vector(ready.get("host_spawn", {}))
	var advanced := _as_vector(ready.get("pre_join_position", {}))
	check(advanced.distance_to(spawn) > 10.0, "Host player already moved before the late join")
	return port

func _launch_client(port: int) -> void:
	var args: PackedStringArray = PackedStringArray([
		"--headless",
		"--path",
		ProjectSettings.globalize_path("res://"),
		"--script",
		CLIENT_FIXTURE,
		"--",
		"--port=%d" % port,
		"--epoch=%d" % MATCH_EPOCH,
		"--out=" + _path("client_result.json"),
		"--log=" + _path(CLIENT_LOG),
		"--max-wait=%d" % FIXTURE_MAX_WAIT_SECONDS,
	])
	client_pid = OS.create_process(OS.get_executable_path(), args, false)
	check(client_pid > 0, "Test fixture starts a real late-joining client Godot process")

func _collect_results(port: int) -> void:
	if client_pid <= 0:
		return
	var deadline := Time.get_ticks_msec() + CLIENT_TIMEOUT_MS
	while Time.get_ticks_msec() < deadline:
		if FileAccess.file_exists(_path("host_result.json")) and FileAccess.file_exists(_path("client_result.json")):
			break
		await create_timer(0.05).timeout
	await _give_processes_time_to_exit()
	var client_result := _read_json(_path("client_result.json"))
	var host_result := _read_json(_path("host_result.json"))
	check(not client_result.is_empty(), "Client process wrote a parseable JSON result")
	check(not host_result.is_empty(), "Host process wrote a parseable JSON result")
	if client_result.is_empty() or host_result.is_empty():
		_dump_log_tail(_path(HOST_LOG))
		_dump_log_tail(_path(CLIENT_LOG))
		return

	check(bool(client_result.get("ok", false)), "Client reports a completed late-join and shutdown scenario")
	check(bool(host_result.get("ok", false)), "Host reports a completed late-join scenario")
	var host_code := _exit_code(host_pid)
	var client_code := _exit_code(client_pid)
	print("EXIT CODES: host=", host_code, " client=", client_code)
	check(host_code == 0, "Host Godot process exits with code 0")
	check(client_code == 0, "Client Godot process exits with code 0")
	if not bool(client_result.get("ok", false)) or not bool(host_result.get("ok", false)):
		print("HOST ERROR: ", host_result.get("error", ""))
		print("CLIENT ERROR: ", client_result.get("error", ""))
		_dump_log_tail(_path(HOST_LOG))
		_dump_log_tail(_path(CLIENT_LOG))
		return

	var host_id := String(host_result.get("host_player_id", ""))
	var remote_id := String(host_result.get("remote_player_id", ""))
	var client_identity: Dictionary = client_result.get("initial_identity", {})
	check(not host_id.is_empty() and not remote_id.is_empty(), "Host and late-joining client have stable distinct ids")
	check(String(client_identity.get("player_id", "")) == remote_id, "Client identity matches the host peer mapping")
	check(int(client_identity.get("match_epoch", -1)) == MATCH_EPOCH, "Client identity carries the match epoch")
	check(int(client_result.get("server_port", 0)) == port, "Client reports the joined server port")

	var client_baseline: Dictionary = client_result.get("baseline", {})
	var host_baseline: Dictionary = host_result.get("baseline_sent", {})
	check(not client_baseline.is_empty(), "Client applied a full baseline")
	check(not host_baseline.is_empty(), "Host recorded the baseline it sent to the late joiner")
	var client_baseline_tick := int(client_baseline.get("baseline_tick", -1))
	var host_baseline_tick := int(host_baseline.get("baseline_tick", -1))
	check(client_baseline_tick > 0, "Baseline carries a positive authority tick")
	check(client_baseline_tick == int(client_baseline.get("server_tick", -2)), "Baseline exposes baseline_tick and server_tick consistently")
	check(client_baseline_tick == host_baseline_tick, "Client baseline is the exact tick the host generated")
	check(client_baseline_tick > int(host_ready.get("pre_join_tick", 0)), "Baseline is newer than the pre-join authority state")
	check(int(client_baseline.get("match_epoch", -1)) == MATCH_EPOCH, "Baseline carries the match epoch")
	check(int(client_result.get("baseline_received_count", 0)) >= 1, "Client session observed baseline_received")
	check(int(client_result.get("baseline_applied_count", 0)) == 1, "Client session marked exactly one baseline applied")
	check(int(client_result.get("bridge_baseline_applied_count", 0)) == 1, "Client bridge applied exactly one baseline")

	var client_players: Dictionary = client_baseline.get("players", {})
	var host_players: Dictionary = host_baseline.get("players", {})
	check(client_players.has(host_id) and client_players.has(remote_id), "Baseline contains every registered player snapshot")
	check(host_players.has(host_id) and host_players.has(remote_id), "Host baseline contains every registered player snapshot")
	check(client_players.size() == host_players.size(), "Client and host baseline agree on the player set")
	for player_key in [host_id, remote_id]:
		var state: Dictionary = client_players.get(player_key, {})
		check(not state.is_empty(), "Baseline carries a snapshot for " + player_key)
		check(int(state.get("tick", -1)) == client_baseline_tick, "Baseline snapshot is stamped with the baseline tick")
		check(int(state.get("revision", -1)) >= 0, "Baseline snapshot carries a per-player revision")
	check(int(client_players.get(host_id, {}).get("revision", -1)) > 0, "Pre-existing host player has already advanced its revision")
	_check_baseline_state_matches(host_players.get(host_id, {}), client_players.get(host_id, {}), "Host player baseline state matches the host authority")

	var duplicate_result: Dictionary = client_result.get("duplicate_baseline_result", {})
	var stale_result: Dictionary = client_result.get("stale_baseline_result", {})
	check(String(duplicate_result.get("reason", "")) == "duplicate_baseline", "Late-join client rejects a duplicate baseline idempotently")
	check(String(stale_result.get("reason", "")) == "stale_baseline", "Late-join client rejects an older baseline idempotently")
	check(bool(client_result.get("baseline_state_stable", false)), "Rejected baselines leave replica state unchanged")

	check(bool(client_result.get("higher_tick_observed", false)), "Client observed a snapshot strictly above the baseline tick")
	check(int(client_result.get("applied_snapshots", 0)) >= 1, "Client applied at least one post-baseline snapshot batch")
	check(int(client_result.get("last_snapshot_tick", -1)) > client_baseline_tick, "Client final snapshot tick advanced beyond the baseline")
	check(bool(client_result.get("progress_sent", false)), "Client reported post-baseline progress to the host")

	check(bool(client_result.get("close_observed", false)), "Client observed the host session close")
	var close_elapsed := int(client_result.get("close_elapsed_ms", -1))
	check(close_elapsed >= 0 and close_elapsed <= CLOSE_BOUND_MS, "Client entered non-combat within a bounded time after host exit")
	check(not bool(client_result.get("session_active_after_close", true)), "Client NetworkSession is explicitly inactive after host exit")
	check(not bool(client_result.get("bridge_can_submit_after_close", true)), "Client bridge refuses command submission after host exit")
	check(not bool(client_result.get("bridge_combat_active_after_close", true)), "Client bridge is explicitly out of combat after host exit")
	check(bool(client_result.get("bridge_session_closed", false)), "Client bridge exposes its session_closed signal state")
	check(not bool(client_result.get("replica_active_after_close", true)), "Client replica is explicitly inactive after host exit")
	check(int(client_result.get("submit_after_close_sequence", 0)) == -1, "A command attempt after host exit is refused")
	check(String(client_result.get("post_close_snapshot_reason", "")) == "not_active", "A snapshot after host exit is refused")
	check(bool(client_result.get("replica_states_stable", false)), "Replica state stops changing after host exit")
	check(int(client_result.get("replica_tick_at_close", -1)) == int(client_result.get("replica_tick_after_wait", -2)), "Replica tick is frozen after host exit")
	check(float(client_result.get("presentation_error_before_close", 0.0)) >= 15.0, "A stale predicted presentation offset existed before the host exit")
	check(int(client_result.get("presentation_render_states_after_close", -1)) == 0, "Host exit drops every client presentation render state")
	check(int(client_result.get("presentation_pending_after_close", -1)) == 0, "Host exit drops pending predicted inputs")
	check(not bool(client_result.get("presentation_ready_after_close", true)), "Host exit marks the client prediction layer unready")
	check(String(client_result.get("presentation_fallback_after_close", "")) == "session_closed", "Host exit exposes the presentation cleanup reason")
	check(float(client_result.get("actor_authority_error_after_close", 99.0)) <= 0.5, "Host exit falls the local actor back to the last authoritative position")

	var host_log := _read_text(_path(HOST_LOG))
	var client_log := _read_text(_path(CLIENT_LOG))
	check(not host_log.contains("SCRIPT ERROR") and not host_log.contains("Parse Error"), "Host fixture log has no script or parse errors")
	check(not client_log.contains("SCRIPT ERROR") and not client_log.contains("Parse Error"), "Client fixture log has no script or parse errors")
	check(not host_log.contains("FAIL") and not client_log.contains("FAIL"), "Fixture logs contain no failed behavior")

func _check_baseline_state_matches(host_state: Dictionary, replica_state: Dictionary, label: String) -> void:
	var host_position := _as_vector(host_state.get("position", {}))
	var replica_position := _as_vector(replica_state.get("position", {}))
	var host_velocity := _as_vector(host_state.get("velocity", {}))
	var replica_velocity := _as_vector(replica_state.get("velocity", {}))
	check(host_position.distance_to(replica_position) <= POSITION_TOLERANCE, label + ": position")
	check(host_velocity.distance_to(replica_velocity) <= POSITION_TOLERANCE, label + ": velocity")
	check(bool(host_state.get("dead", false)) == bool(replica_state.get("dead", true)), label + ": alive/dead state")

func _as_vector(value: Variant) -> Vector2:
	if value is Vector2:
		return value
	if value is Dictionary:
		return Vector2(float(value.get("x", 0.0)), float(value.get("y", 0.0)))
	return Vector2.ZERO

func _give_processes_time_to_exit() -> void:
	var deadline := Time.get_ticks_msec() + EXIT_TIMEOUT_MS
	while Time.get_ticks_msec() < deadline:
		var host_running := host_pid > 0 and OS.is_process_running(host_pid)
		var client_running := client_pid > 0 and OS.is_process_running(client_pid)
		if not host_running and not client_running:
			break
		await create_timer(0.05).timeout
	if (host_pid > 0 and OS.is_process_running(host_pid)) or (client_pid > 0 and OS.is_process_running(client_pid)):
		_kill_children()
		await create_timer(0.25).timeout

func _kill_children() -> void:
	for pid in [host_pid, client_pid]:
		if pid > 0 and OS.is_process_running(pid):
			OS.kill(pid)

func _exit_code(pid: int) -> int:
	if pid <= 0:
		return -1
	if OS.is_process_running(pid):
		return -2
	return OS.get_process_exit_code(pid)

func _wait_for_json(path: String, pid: int, timeout_ms: int) -> Dictionary:
	var deadline := Time.get_ticks_msec() + timeout_ms
	while Time.get_ticks_msec() < deadline:
		if FileAccess.file_exists(path):
			return _read_json(path)
		if not OS.is_process_running(pid):
			return _read_json(path)
		await create_timer(0.05).timeout
	return _read_json(path)

func _read_json(path: String) -> Dictionary:
	if not FileAccess.file_exists(path):
		return {}
	var text := FileAccess.get_file_as_string(path)
	var parsed: Variant = JSON.parse_string(text)
	if parsed is Dictionary:
		return parsed
	print("PARSE ERROR: ", path, " -> ", text)
	return {}

func _read_text(path: String) -> String:
	if not FileAccess.file_exists(path):
		return ""
	return FileAccess.get_file_as_string(path)

func _dump_log_tail(path: String) -> void:
	var text := _read_text(path)
	if text.is_empty():
		print("LOG EMPTY: ", path)
		return
	var lines := text.split("\n", false)
	var first := maxi(lines.size() - 30, 0)
	print("--- tail ", path, " ---")
	for index in range(first, lines.size()):
		print(lines[index])

func _path(file_name: String) -> String:
	return artifact_dir_abs.path_join(file_name)

func _remove_if_present(path: String) -> void:
	if FileAccess.file_exists(path):
		DirAccess.remove_absolute(path)
