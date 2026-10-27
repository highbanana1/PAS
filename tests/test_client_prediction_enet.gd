extends SceneTree

## Ticket 02B2B real-ENet behavior test. Two actual Godot processes run the
## same host-authoritative match seam as 02B1/02B2A, but with client-side
## presentation enabled:
##   * the client submits local input through MatchNetworkBridge.submit_move and
##     must observe a predicted render position before any newer snapshot;
##   * remote presentation must interpolate between authoritative server ticks
##     instead of snapping to each 20 Hz snapshot;
##   * a deliberately injected prediction error must converge back to the
##     authoritative position inside a bounded time;
##   * after the authority settles, both the local and remote presentation and
##     the authoritative replica must agree with the host's final snapshot.
## No fixed ports, no public network access, no authority writes from the
## presentation layer.

const BRIDGE_PATH := "res://scene/script/network/match_network_bridge.gd"
const VIEW_PATH := "res://scene/script/network/client_motion_view.gd"
const HOST_FIXTURE := "res://tests/fixtures/network_match_host.gd"
const CLIENT_FIXTURE := "res://tests/fixtures/network_match_client.gd"
const MATCH_EPOCH := 626262
const FIXTURE_MAX_WAIT_SECONDS := 22
const HOST_TIMEOUT_MS := 30000
const CLIENT_TIMEOUT_MS := 35000
const EXIT_TIMEOUT_MS := 10000
const POSITION_TOLERANCE := 0.25
const VELOCITY_TOLERANCE := 0.25
const LOCAL_RENDER_TOLERANCE := 0.5
const REMOTE_RENDER_TOLERANCE := 1.0
const CONVERGENCE_BOUND_MS := 1500
const HOST_LOG := "host_fixture.log"
const CLIENT_LOG := "client_fixture.log"

var failures: Array[String] = []
var host_pid: int = -1
var client_pid: int = -1
var artifact_dir_abs: String = ""

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
	print("TEST: client prediction, remote interpolation and authoritative correction over real ENet")
	artifact_dir_abs = OS.get_temp_dir().path_join("pas-ticket02b2b-%d" % OS.get_process_id())
	DirAccess.make_dir_recursive_absolute(artifact_dir_abs)
	for file_name in ["host_ready.json", "host_result.json", "client_result.json", HOST_LOG, CLIENT_LOG]:
		_remove_if_present(_path(file_name))

	var bridge_script = load(BRIDGE_PATH)
	var view_script = load(VIEW_PATH)
	check(bridge_script != null and bridge_script.can_instantiate(), "MatchNetworkBridge exposes a loadable public module")
	check(view_script != null and view_script.can_instantiate(), "ClientMotionView exposes a loadable presentation module")
	if bridge_script == null or not bridge_script.can_instantiate() or view_script == null or not view_script.can_instantiate():
		_finish()
		return
	check(_has_method(bridge_script, "inject_prediction_error"), "Bridge exposes the presentation-only error probe")
	check(_has_method(bridge_script, "get_render_position"), "Bridge exposes render positions without changing the replica")

	var port := await _launch_and_wait_for_host()
	if port <= 0:
		_kill_children()
		_finish()
		return
	_launch_client(port)
	await _collect_results()
	_kill_children()
	_finish()

func _has_method(script: Script, method_name: String) -> bool:
	for method: Dictionary in script.get_script_method_list():
		if String(method.get("name", "")) == method_name:
			return true
	return false

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
		"--motion=1",
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
	check(not ready.is_empty(), "Host process publishes readiness without a fixed port")
	if ready.is_empty():
		_dump_log_tail(_path(HOST_LOG))
		return 0
	check(bool(ready.get("ok", false)), "Host process reports a successful ENet listen")
	var port := int(ready.get("port", 0))
	check(port > 0, "Host readiness carries a positive ephemeral port")
	check(int(ready.get("epoch", -1)) == MATCH_EPOCH, "Host readiness carries the match epoch")
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
		"--motion=1",
		"--out=" + _path("client_result.json"),
		"--log=" + _path(CLIENT_LOG),
		"--max-wait=%d" % FIXTURE_MAX_WAIT_SECONDS,
	])
	client_pid = OS.create_process(OS.get_executable_path(), args, false)
	check(client_pid > 0, "Test fixture starts a real client Godot process")

func _collect_results() -> void:
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

	check(bool(client_result.get("ok", false)), "Client reports a completed prediction/interpolation scenario")
	check(bool(host_result.get("ok", false)), "Host reports a completed authoritative scenario")
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

	check(bool(host_result.get("motion_mode", false)), "Host ran the motion presentation scenario")
	check(bool(client_result.get("motion_mode", false)), "Client ran the motion presentation scenario")

	_check_prediction(client_result)
	_check_remote_interpolation(client_result)
	_check_correction(client_result)
	_check_final_convergence(host_result, client_result)

	var host_log := _read_text(_path(HOST_LOG))
	var client_log := _read_text(_path(CLIENT_LOG))
	check(not host_log.contains("SCRIPT ERROR") and not host_log.contains("Parse Error"), "Host fixture log has no script or parse errors")
	check(not client_log.contains("SCRIPT ERROR") and not client_log.contains("Parse Error"), "Client fixture log has no script or parse errors")
	check(not host_log.contains("FAIL") and not client_log.contains("FAIL"), "Fixture logs contain no failed behavior")

func _check_prediction(client_result: Dictionary) -> void:
	check(bool(client_result.get("prediction_observable", false)), "Local input produced an observable prediction before any newer snapshot")
	var probe: Dictionary = client_result.get("prediction_probe", {})
	check(int(probe.get("sequence", -1)) > 0, "The predicted input has a NetworkSession sequence")
	check(float(probe.get("moved", 0.0)) > 0.5, "The predicted render position moved immediately")
	check(int(probe.get("before_applied_snapshots", -1)) == int(probe.get("after_applied_snapshots", -2)), "Prediction was observed with no snapshot applied in between")
	check(int(probe.get("before_snapshot_tick", -1)) == int(probe.get("after_snapshot_tick", -2)), "Prediction was observed before the next 20 Hz server tick arrived")
	check(int(probe.get("pending_inputs", 0)) >= 1, "The predicted input remains pending for authoritative confirmation")
	check(int(client_result.get("pending_inputs_at_finish", -1)) == 0, "Every predicted input was confirmed by the end of the scenario")
	var prediction: Dictionary = client_result.get("client_prediction", {})
	check(int(prediction.get("last_ack_sequence", 0)) > 0, "The client observed authoritative sequence acknowledgements")
	check(bool(prediction.get("ready", false)), "Client prediction reports a ready local view")
	check(int(prediction.get("pending_input_count", -1)) == 0, "Client prediction holds no unconfirmed input at finish")
	check(not bool(client_result.get("client_has_authority", true)), "The client presentation path owns no MatchAuthority")
	check(not bool(client_result.get("client_is_host_authority", true)), "The client bridge is not a host authority")

func _check_remote_interpolation(client_result: Dictionary) -> void:
	check(int(client_result.get("remote_min_samples", 0)) >= 2, "Remote player kept at least two ordered server-tick samples")
	check(int(client_result.get("remote_interpolated_frames", 0)) >= 5, "Remote player rendered on interpolated frames between snapshots")
	check(int(client_result.get("remote_off_authority_frames", 0)) > 0, "Remote render did not simply copy the newest authoritative position every frame")
	var snapshot_step := float(client_result.get("max_snapshot_step", 0.0))
	var render_step := float(client_result.get("remote_max_render_step", 0.0))
	check(snapshot_step > 0.0, "The scenario observed authoritative snapshot movement")
	check(render_step < snapshot_step, "Remote rendering advanced in smaller steps than raw snapshot jumps")
	var fallback := String(client_result.get("remote_fallback_reason", ""))
	check(fallback.is_empty() or fallback.contains("remote_"), "Remote fallback state is explicit if it occurred")

func _check_correction(client_result: Dictionary) -> void:
	check(bool(client_result.get("injection_accepted", false)), "The deliberate prediction error was injected through the presentation seam")
	check(float(client_result.get("post_injection_error", 0.0)) > 5.0, "The injected error is observable in presentation space")
	var converged := float(client_result.get("converged_error", -1.0))
	var convergence_ms := int(client_result.get("convergence_ms", -1))
	check(converged >= 0.0 and converged <= LOCAL_RENDER_TOLERANCE, "The injected prediction error converged to the authoritative position")
	check(convergence_ms >= 0 and convergence_ms <= CONVERGENCE_BOUND_MS, "The injected prediction error converged inside a bounded time")
	var prediction: Dictionary = client_result.get("client_prediction", {})
	check(int(prediction.get("large_correction_count", 0)) == 0, "The small injected error used smooth correction rather than a hard snap")

func _check_final_convergence(host_result: Dictionary, client_result: Dictionary) -> void:
	var host_id := String(host_result.get("host_player_id", ""))
	var remote_id := String(host_result.get("remote_player_id", ""))
	var client_identity: Dictionary = client_result.get("initial_identity", {})
	check(String(client_identity.get("player_id", "")) == remote_id, "Client identity matches the host peer mapping")
	var host_final: Dictionary = host_result.get("host_final", {})
	var remote_final: Dictionary = host_result.get("remote_final", {})
	var client_states: Dictionary = client_result.get("replica_states", {})
	check(client_states.has(host_id) and client_states.has(remote_id), "Client authoritative replica contains both players")
	if client_states.has(host_id) and client_states.has(remote_id):
		_check_state_matches(host_final, client_states[host_id], "Host player replica matches host final snapshot")
		_check_state_matches(remote_final, client_states[remote_id], "Remote player replica matches host final snapshot")
	check(float(client_result.get("local_final_error", -1.0)) >= 0.0 and float(client_result.get("local_final_error", 99.0)) <= LOCAL_RENDER_TOLERANCE, "Local predicted presentation converged to the authoritative position")
	check(float(client_result.get("remote_final_error", -1.0)) >= 0.0 and float(client_result.get("remote_final_error", 99.0)) <= REMOTE_RENDER_TOLERANCE, "Remote interpolated presentation converged to the authoritative position")
	var commands_sent := int(client_result.get("commands_sent", 0))
	var remote_ack := int(host_result.get("remote_final_ack_sequence", -1))
	check(commands_sent > 0, "Client submitted local movement through the bridge")
	check(remote_ack == commands_sent, "Host authoritative snapshot acknowledged exactly the client's sequences")
	var last_batch: Dictionary = host_result.get("last_batch", {})
	var players: Dictionary = last_batch.get("players", {})
	check(players.has(host_id) and players.has(remote_id), "Host snapshot carries both authoritative players")
	if players.has(remote_id):
		var remote_state: Dictionary = players[remote_id]
		check(int(remote_state.get("ack_sequence", -1)) >= 0, "Authoritative snapshot carries the per-player acknowledgement")

func _check_state_matches(host_state: Dictionary, replica_state: Dictionary, label: String) -> void:
	var host_position := _as_vector(host_state.get("position", {}))
	var replica_position := _as_vector(replica_state.get("position", {}))
	var host_velocity := _as_vector(host_state.get("velocity", {}))
	var replica_velocity := _as_vector(replica_state.get("velocity", {}))
	check(host_position.distance_to(replica_position) <= POSITION_TOLERANCE, label + ": position")
	check(host_velocity.distance_to(replica_velocity) <= VELOCITY_TOLERANCE, label + ": velocity")
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
