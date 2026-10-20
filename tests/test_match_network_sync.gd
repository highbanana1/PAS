extends SceneTree

## Ticket 02B1 real-ENet seam test. It launches two actual Godot processes: a
## host that drains NetworkSession's validated command queue into
## MatchAuthority and broadcasts authoritative snapshots, and a client that
## joins, submits only its own movement and receives those snapshots. The test
## compares the client's snapshot-derived replica with the host's final
## authoritative snapshot. No fixed ports and no public network access.

const BRIDGE_PATH := "res://scene/script/network/match_network_bridge.gd"
const REPLICA_PATH := "res://scene/script/network/snapshot_replica.gd"
const HOST_FIXTURE := "res://tests/fixtures/network_match_host.gd"
const CLIENT_FIXTURE := "res://tests/fixtures/network_match_client.gd"
const MATCH_EPOCH := 424242
const FIXTURE_MAX_WAIT_SECONDS := 18
const HOST_TIMEOUT_MS := 30000
const CLIENT_TIMEOUT_MS := 30000
const EXIT_TIMEOUT_MS := 10000
const POSITION_TOLERANCE := 0.25
const VELOCITY_TOLERANCE := 0.25
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
	print("TEST: MatchAuthority host-authoritative snapshot sync over real ENet")
	artifact_dir_abs = OS.get_temp_dir().path_join("pas-ticket02b1-%d" % OS.get_process_id())
	DirAccess.make_dir_recursive_absolute(artifact_dir_abs)
	for file_name in ["host_ready.json", "host_result.json", "client_result.json", HOST_LOG, CLIENT_LOG]:
		_remove_if_present(_path(file_name))

	var bridge_script = load(BRIDGE_PATH)
	var replica_script = load(REPLICA_PATH)
	check(bridge_script != null and bridge_script.can_instantiate(), "MatchNetworkBridge exposes a loadable public module")
	check(replica_script != null and replica_script.can_instantiate(), "SnapshotReplica exposes a loadable public module")
	if bridge_script == null or not bridge_script.can_instantiate() or replica_script == null or not replica_script.can_instantiate():
		_finish()
		return

	_check_contract(bridge_script, replica_script)
	_test_replica_rejection(replica_script)
	var port := await _launch_and_wait_for_host()
	if port <= 0:
		_kill_children()
		_finish()
		return
	_launch_client(port)
	await _collect_results(port)
	_kill_children()
	_finish()

func _check_contract(bridge_script: Script, replica_script: Script) -> void:
	check(int(bridge_script.AUTHORITY_HZ) == 60, "Bridge declares a 60 Hz authority step")
	check(int(bridge_script.SNAPSHOT_HZ) == 20, "Bridge declares an initial 20 Hz snapshot cadence")
	check(is_equal_approx(float(bridge_script.SNAPSHOT_INTERVAL), 1.0 / 20.0), "Bridge derives the snapshot interval from 20 Hz")
	check(String(replica_script.REJECT_STALE_EPOCH) == "stale_epoch", "Replica names the stale-epoch rejection")
	check(String(replica_script.REJECT_REGRESSED_TICK) == "regressed_tick", "Replica names the regressed-tick rejection")

func _test_replica_rejection(replica_script: Script) -> void:
	var replica = replica_script.new()
	replica.configure(MATCH_EPOCH)
	var early := _batch(MATCH_EPOCH, 10, "player_2", Vector2(555.0, 555.0), Vector2.ZERO, 2, false)
	var early_result: Dictionary = replica.apply_batch(early)
	check(not bool(early_result.get("applied", true)) and String(early_result.get("reason", "")) == "baseline_required", "Replica rejects a snapshot that arrives before the baseline")
	check(replica.get_states().is_empty(), "A pre-baseline snapshot does not populate the replica")

	var baseline := {
		"match_epoch": MATCH_EPOCH,
		"baseline_tick": 10,
		"server_tick": 10,
		"players": {
			"player_2": {
				"player_id": "player_2",
				"tick": 10,
				"revision": 2,
				"position": Vector2(4.0, 4.0),
				"velocity": Vector2.ZERO,
				"dead": false,
				"health": 150.0,
				"max_health": 150.0,
			},
		},
	}
	var baseline_result: Dictionary = replica.apply_baseline(baseline)
	check(bool(baseline_result.get("applied", false)), "Replica applies the reliable full baseline")
	check(bool(replica.has_baseline()), "Replica reports its baseline as applied")
	check(int(replica.get_last_tick()) == 10, "Replica records the baseline tick")
	var duplicate_baseline: Dictionary = replica.apply_baseline(baseline)
	check(String(duplicate_baseline.get("reason", "")) == "duplicate_baseline", "Replica idempotently rejects a duplicate baseline")
	var stale_baseline := baseline.duplicate(true)
	stale_baseline["baseline_tick"] = 9
	stale_baseline["server_tick"] = 9
	var old_baseline: Dictionary = replica.apply_baseline(stale_baseline)
	check(String(old_baseline.get("reason", "")) == "stale_baseline", "Replica idempotently rejects an older baseline")
	check(int(replica.get_last_tick()) == 10, "Rejected baselines leave the applied tick untouched")

	var batch := _batch(MATCH_EPOCH, 11, "player_2", Vector2(12.0, 4.0), Vector2(5.0, 0.0), 3, false)
	var first: Dictionary = replica.apply_batch(batch)
	check(bool(first.get("applied", false)), "Replica accepts a fresh authoritative snapshot batch above the baseline")
	check(int(replica.get_last_tick()) == 11, "Replica records the applied server tick")
	var applied_state: Dictionary = replica.get_state("player_2")
	check(not applied_state.is_empty() and applied_state.get("position", Vector2.ZERO).is_equal_approx(Vector2(12.0, 4.0)), "Replica exposes the applied player state")

	var duplicate: Dictionary = replica.apply_batch(batch)
	check(not bool(duplicate.get("applied", true)) and String(duplicate.get("reason", "")) == "regressed_tick", "Replica rejects a duplicate server tick as regressed")
	var regressed: Dictionary = replica.apply_batch(_batch(MATCH_EPOCH, 10, "player_2", Vector2(999.0, 999.0), Vector2.ZERO, 4, false))
	check(not bool(regressed.get("applied", true)) and String(regressed.get("reason", "")) == "regressed_tick", "Replica rejects a regressed server tick")
	var stale_epoch: Dictionary = replica.apply_batch(_batch(MATCH_EPOCH - 1, 12, "player_2", Vector2(777.0, 777.0), Vector2.ZERO, 5, false))
	check(not bool(stale_epoch.get("applied", true)) and String(stale_epoch.get("reason", "")) == "stale_epoch", "Replica rejects a stale match epoch")
	var still_applied: Dictionary = replica.get_state("player_2")
	check(still_applied.get("position", Vector2.ZERO).is_equal_approx(Vector2(12.0, 4.0)), "Rejected snapshots do not move the replica")
	check(int(replica.get_last_tick()) == 11, "Rejected snapshots do not advance the replica tick")
	check(int(replica.get_rejected_count("regressed_tick")) == 2, "Replica counts both regressed and duplicate batches")
	check(int(replica.get_rejected_count("stale_epoch")) == 1, "Replica counts stale-epoch batches")

func _batch(epoch: int, tick: int, player_id: String, position: Vector2, velocity: Vector2, revision: int, dead: bool) -> Dictionary:
	return {
		"match_epoch": epoch,
		"server_tick": tick,
		"players": {
			player_id: {
				"player_id": player_id,
				"tick": tick,
				"revision": revision,
				"position": position,
				"velocity": velocity,
				"dead": dead,
				"health": 150.0,
				"max_health": 150.0,
			},
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
		"--out=" + _path("client_result.json"),
		"--log=" + _path(CLIENT_LOG),
		"--max-wait=%d" % FIXTURE_MAX_WAIT_SECONDS,
	])
	client_pid = OS.create_process(OS.get_executable_path(), args, false)
	check(client_pid > 0, "Test fixture starts a real client Godot process")

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

	check(bool(client_result.get("ok", false)), "Client reports a completed snapshot-sync scenario")
	check(bool(host_result.get("ok", false)), "Host reports a completed snapshot-sync scenario")
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
	var host_identity: Dictionary = host_result.get("host_identity", {})
	var remote_identity: Dictionary = host_result.get("remote_identity", {})
	var client_identity: Dictionary = client_result.get("initial_identity", {})
	check(not host_identity.is_empty(), "Host owns a stable local player identity")
	check(not remote_identity.is_empty(), "Server mapped the connected peer to a stable player identity")
	check(not client_identity.is_empty(), "Client received the authoritative identity")
	check(String(client_identity.get("player_id", "")) == remote_id, "Client player id matches the server peer mapping")
	check(int(client_identity.get("match_epoch", -1)) == MATCH_EPOCH, "Client received the match epoch")
	check(int(client_result.get("server_port", 0)) == port, "Client reports the joined server port")
	check(String(host_identity.get("player_id", "")) != remote_id, "Host and client have distinct stable player ids")

	var host_final: Dictionary = host_result.get("host_final", {})
	var remote_final: Dictionary = host_result.get("remote_final", {})
	var client_states: Dictionary = client_result.get("replica_states", {})
	check(not host_final.is_empty(), "Host exposes its final authoritative host-player snapshot")
	check(not remote_final.is_empty(), "Host exposes its final authoritative remote-player snapshot")
	check(client_states.has(host_id) and client_states.has(remote_id), "Client replica contains both authoritative players")
	if client_states.has(host_id) and client_states.has(remote_id):
		_check_state_matches(host_final, client_states[host_id], "Host player replica matches host final snapshot")
		_check_state_matches(remote_final, client_states[remote_id], "Remote player replica matches host final snapshot")
		check(int(client_states[host_id].get("revision", 0)) > 0, "Client replica carries the host player revision")
		check(int(client_states[remote_id].get("revision", 0)) > 0, "Client replica carries the remote player revision")

	check(bool(remote_final.get("dead", false)), "Host authoritative remote player is dead at the end of the scenario")
	check(bool(client_states.get(remote_id, {}).get("dead", false)), "Client replica observes the authoritative dead state")
	var host_initial := _as_vector(host_result.get("host_initial_position", {}))
	var host_final_position := _as_vector(host_final.get("position", {}))
	var remote_initial := _as_vector(host_result.get("remote_initial_position", {}))
	var remote_final_position := _as_vector(remote_final.get("position", {}))
	check(host_final_position.distance_to(host_initial) > 10.0, "Host local input moved the authoritative host actor")
	check(remote_final_position.distance_to(remote_initial) > 10.0, "Client input moved the authoritative remote actor")
	check(host_final_position.x > host_initial.x, "Host local input moved in the submitted direction")

	var applied := int(client_result.get("applied_snapshots", 0))
	var target_tick := int(host_result.get("target_tick", -1))
	var client_tick := int(client_result.get("last_snapshot_tick", -1))
	check(applied >= 3, "Client received multiple authoritative snapshot batches")
	check(target_tick > 0, "Host recorded a final target server tick")
	check(client_tick >= target_tick, "Client applied a snapshot at or beyond the final target tick")
	check(int(client_result.get("stale_epoch_rejections", 0)) >= 1, "Client replica observed and rejected a stale-epoch batch")
	check(int(client_result.get("regressed_tick_rejections", 0)) >= 1, "Client replica observed and rejected a regressed-tick batch")

	var last_batch: Dictionary = client_result.get("last_batch", {})
	check(int(last_batch.get("match_epoch", -1)) == MATCH_EPOCH, "Snapshot batch carries the match epoch")
	check(int(last_batch.get("server_tick", 0)) > 0, "Snapshot batch carries a positive server tick")
	var last_players: Dictionary = last_batch.get("players", {})
	check(last_players.has(host_id) and last_players.has(remote_id), "Snapshot batch carries every authoritative player")
	for player_key in [host_id, remote_id]:
		var player_state: Dictionary = last_players.get(player_key, {})
		check(String(player_state.get("player_id", "")) == player_key, "Snapshot carries the stable player id")
		check(int(player_state.get("revision", 0)) > 0, "Snapshot carries a positive per-player revision")

	var host_sent := int(host_result.get("host_commands_sent", 0))
	var command_counts: Dictionary = host_result.get("command_counts", {})
	check(host_sent > 0, "Host submitted local movement commands")
	check(int(command_counts.get(host_id, 0)) == host_sent, "Every host local command was consumed from the NetworkSession queue")
	check(int(command_counts.get(remote_id, 0)) > 0, "Remote client commands were consumed from the NetworkSession queue")
	var forged_claims: Array = host_result.get("forged_claims", [])
	check(forged_claims.size() >= 1, "Host observed the client's forged player_id claim")
	if forged_claims.size() >= 1:
		var claim: Dictionary = forged_claims[0]
		check(String(claim.get("actual_player_id", "")) == remote_id, "Forged claim was bound to the remote sender's player id")
		check(String(claim.get("claimed_player_id", "")) == host_id, "Host recorded but did not trust the forged player id")
	check(int(command_counts.get(host_id, 0)) == host_sent, "Forged claim did not add a command to the host player's authority queue")

	var authority_steps := int(host_result.get("authority_steps", 0))
	var physics_frames := int(host_result.get("physics_frames", 0))
	var snapshots_sent := int(host_result.get("snapshots_sent", 0))
	check(authority_steps > 0 and physics_frames > 0, "Host bridge observed fixed authority steps and physics frames")
	check(float(authority_steps) >= float(physics_frames) * 0.5, "Authority advanced on the host physics cadence")
	check(snapshots_sent > 0, "Host broadcast authoritative snapshot batches")
	var expected_snapshots := float(authority_steps) / 3.0
	check(absf(float(snapshots_sent) - expected_snapshots) <= 5.0, "Snapshot cadence is approximately one batch per three authority steps")

	var host_log := _read_text(_path(HOST_LOG))
	var client_log := _read_text(_path(CLIENT_LOG))
	check(not host_log.contains("SCRIPT ERROR") and not host_log.contains("Parse Error"), "Host fixture log has no script or parse errors")
	check(not client_log.contains("SCRIPT ERROR") and not client_log.contains("Parse Error"), "Client fixture log has no script or parse errors")

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
	var first := maxi(lines.size() - 25, 0)
	print("--- tail ", path, " ---")
	for index in range(first, lines.size()):
		print(lines[index])

func _path(file_name: String) -> String:
	return artifact_dir_abs.path_join(file_name)

func _remove_if_present(path: String) -> void:
	if FileAccess.file_exists(path):
		DirAccess.remove_absolute(path)
