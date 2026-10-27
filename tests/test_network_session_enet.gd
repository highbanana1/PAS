extends SceneTree

## Ticket 02A real-ENet seam test. It launches two actual Godot processes: one
## hosts a NetworkSession with an ephemeral UDP port, the other joins over
## localhost, receives its stable identity, and exercises the command envelope.
## No fixed ports and no public network access.

const SESSION_PATH := "res://scene/script/network/network_session.gd"
const HOST_FIXTURE := "res://tests/fixtures/network_session_host.gd"
const CLIENT_FIXTURE := "res://tests/fixtures/network_session_client.gd"
const MATCH_EPOCH := 424242
const FIXTURE_MAX_WAIT_SECONDS := 15
const HOST_TIMEOUT_MS := 25000
const CLIENT_TIMEOUT_MS := 25000
const EXIT_TIMEOUT_MS := 8000
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
	print("TEST: NetworkSession real ENet two-process seam")
	artifact_dir_abs = OS.get_temp_dir().path_join("pas-ticket02-%d" % OS.get_process_id())
	DirAccess.make_dir_recursive_absolute(artifact_dir_abs)
	_remove_if_present(_path("host_ready.json"))
	_remove_if_present(_path("host_result.json"))
	_remove_if_present(_path("client_result.json"))
	_remove_if_present(_path(HOST_LOG))
	_remove_if_present(_path(CLIENT_LOG))

	var session_script = load(SESSION_PATH)
	check(session_script != null and session_script.can_instantiate(), "NetworkSession exposes a loadable public module")
	if session_script == null or not session_script.can_instantiate():
		_finish()
		return

	_check_capacity_contract(session_script)
	var port := await _launch_and_wait_for_host()
	if port <= 0:
		_kill_children()
		_finish()
		return
	_launch_client(port)
	await _collect_results(port)
	_kill_children()
	_finish()

func _check_capacity_contract(session_script: Script) -> void:
	check(int(session_script.MAX_SEATS) == 16, "NetworkSession contract caps a room at 16 seats")
	check(int(session_script.MAX_REMOTE_CLIENTS) == 15, "NetworkSession reserves one seat for the host")
	check(int(session_script.INITIAL_LIFE_ID) == 1, "NetworkSession starts a player at life id 1")
	check(String(session_script.REJECT_STALE_EPOCH) == "stale_epoch", "NetworkSession names the stale-epoch result")
	check(String(session_script.REJECT_STALE_LIFE) == "stale_life", "NetworkSession names the stale-life result")
	check(String(session_script.REJECT_DUPLICATE_SEQUENCE) == "duplicate_sequence", "NetworkSession names the duplicate-sequence result")
	check(String(session_script.REJECT_REGRESSED_SEQUENCE) == "regressed_sequence", "NetworkSession names the regressed-sequence result")

	var session = session_script.new()
	session.name = "CapacityProbe"
	root.add_child(session)
	var rejected_oversize: int = session.host(0, {"seats": 17, "match_epoch": MATCH_EPOCH})
	check(rejected_oversize == ERR_INVALID_PARAMETER, "Host rejects a requested capacity above 16 seats")
	check(not session.is_active(), "A rejected oversize host request leaves no active session")
	var hosted: int = session.host(0, {"seats": 16, "match_epoch": MATCH_EPOCH})
	check(hosted == OK, "Host creates a 16-seat session on an ephemeral localhost port")
	check(session.get_port() > 0, "Host reports the actual ephemeral ENet port")
	check(session.get_match_epoch() == MATCH_EPOCH, "Host keeps the configured match epoch")
	check(session.get_max_seats() == 16, "Host reports 16 total seats")
	check(session.get_remote_capacity() == 15, "Host exposes 15 remote seats")
	check(session.get_player_count() == 1, "Host occupies exactly one seat at creation")
	check(not session.get_local_identity().is_empty(), "Host has its own authoritative identity")
	session.stop()
	check(not session.is_active(), "Stopping the host closes the session")
	root.remove_child(session)
	session.free()

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
		print("HOST LOG: ", _path(HOST_LOG))
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
		print("HOST LOG: ", _path(HOST_LOG))
		print("CLIENT LOG: ", _path(CLIENT_LOG))
		_dump_log_tail(_path(HOST_LOG))
		_dump_log_tail(_path(CLIENT_LOG))
		return

	check(bool(client_result.get("ok", false)), "Client reports a completed ENet scenario")
	check(bool(host_result.get("ok", false)), "Host reports a completed ENet scenario")
	var host_code := _exit_code(host_pid)
	var client_code := _exit_code(client_pid)
	print("EXIT CODES: host=", host_code, " client=", client_code)
	check(host_code == 0, "Host Godot process exits with code 0")
	check(client_code == 0, "Client Godot process exits with code 0")

	var host_identity: Dictionary = host_result.get("local_identity", {})
	var mapped_identity: Dictionary = host_result.get("client_identity", {})
	var client_identity: Dictionary = client_result.get("initial_identity", {})
	check(not host_identity.is_empty(), "Host owns a stable local player identity")
	check(not mapped_identity.is_empty(), "Server recorded a stable identity for the connected peer")
	check(not client_identity.is_empty(), "Client received the authoritative identity")
	check(String(client_identity.get("player_id", "")) == String(mapped_identity.get("player_id", "")), "Client player id matches the server peer mapping")
	check(int(client_identity.get("peer_id", -1)) == int(mapped_identity.get("peer_id", -2)), "Client peer id matches the server peer mapping")
	check(int(client_identity.get("match_epoch", -1)) == MATCH_EPOCH, "Client received the match epoch")
	check(int(client_identity.get("life_id", -1)) == 1, "Client received its initial life id")
	check(int(client_result.get("server_port", 0)) == port, "Client reports the joined server port")
	check(String(host_result.get("mapped_player_id", "")) == String(client_identity.get("player_id", "")), "Server forward lookup maps peer id to the stable player id")
	check(int(host_result.get("reverse_peer_id", -1)) == int(mapped_identity.get("peer_id", -2)), "Server reverse lookup maps player id to peer id")
	check(int(client_result.get("final_identity", {}).get("life_id", -1)) == 2, "Client received the authoritative life update")

	var commands: Array = host_result.get("commands", [])
	var rejections: Array = host_result.get("rejections", [])
	check(commands.size() == 3, "Server queued exactly the three valid gameplay commands")
	check(rejections.size() == 4, "Server rejected exactly the four stale or duplicate commands")
	check(bool(host_result.get("life_change_requested", false)), "Life-change trigger arrived over the reliable fixture control channel")
	check(bool(host_result.get("life_change_ok", false)), "Host advanced the authoritative life id")
	var moves := _commands_of_type(commands, "move")
	check(moves.size() == 2, "Both valid move commands are observable in the server queue")
	check(_first_command(commands, "fixture_finish") == null, "Finish handshake is not queued as a gameplay command")
	check(not _has_fixture_command(commands), "No fixture-only control message entered the gameplay command queue")
	check(bool(host_result.get("finish_verified", false)), "Host verified the final valid gameplay command before finishing")
	check(int(host_result.get("final_command_sequence", -1)) == 101 and int(host_result.get("final_command_life_id", -1)) == 2, "Host closed only after the life-2 command with sequence 101")
	check(bool(host_result.get("finish_ack_sent", false)), "Host sent the reliable finish acknowledgement")
	check(bool(client_result.get("finish_acknowledged", false)), "Client received the reliable finish acknowledgement before closing")

	var forged: Variant = moves[0] if moves.size() > 0 else null
	check(forged != null, "Forged-payload command was accepted for the real sender")
	if forged != null:
		check(int(forged.get("sequence", -1)) == 1 and int(forged.get("life_id", -1)) == 1, "The forged-payload command kept its original envelope")
		check(String(forged.get("player_id", "")) == String(mapped_identity.get("player_id", "")), "Server binds command identity to the remote sender")
		check(String(forged.get("claimed_player_id", "")) == "player_999", "Server records but does not trust the forged payload player id")
		var payload: Dictionary = forged.get("command", {})
		check(String(payload.get("player_id", "")) != "player_999", "Queued command does not retain the forged player id")

	check(_has_rejection(rejections, "duplicate_sequence"), "Duplicate sequence is rejected")
	check(_has_rejection(rejections, "regressed_sequence"), "Regressed sequence is rejected")
	check(_has_rejection(rejections, "stale_epoch"), "Stale match epoch is rejected")
	check(_has_rejection(rejections, "stale_life"), "Stale life id is rejected")
	var high: Variant = _first_command(commands, "jump")
	check(high != null and int(high.get("sequence", -1)) == 10, "Server accepts a higher sequence after a duplicate")
	var life_two: Variant = moves[1] if moves.size() > 1 else null
	check(life_two != null and int(life_two.get("life_id", -1)) == 2 and int(life_two.get("sequence", -1)) == 101, "A post-life-change move is accepted with life id 2")
	var life_two_commands := _commands_with_life(commands, 2)
	check(life_two_commands.size() == 1, "Only the post-life-change gameplay command carries the new life id")

	var acks: Array = client_result.get("acks", [])
	check(acks.size() == 7, "Client observed a result for every gameplay command envelope")
	check(_acks_contain(acks, "duplicate_sequence"), "Client observes duplicate-sequence rejection")
	check(_acks_contain(acks, "regressed_sequence"), "Client observes regressed-sequence rejection")
	check(_acks_contain(acks, "stale_epoch"), "Client observes stale-epoch rejection")
	check(_acks_contain(acks, "stale_life"), "Client observes stale-life rejection")
	check(port > 0, "Two processes connected through the ephemeral localhost port")
	var host_log := _read_text(_path(HOST_LOG))
	var client_log := _read_text(_path(CLIENT_LOG))
	check(host_log.contains("finish verified"), "Host fixture log preserves the verified finish handshake")
	check(client_log.contains("reliable finish acknowledgement received"), "Client fixture log preserves the reliable finish acknowledgement")

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
	var first := maxi(lines.size() - 20, 0)
	print("--- tail ", path, " ---")
	for index in range(first, lines.size()):
		print(lines[index])

func _path(file_name: String) -> String:
	return artifact_dir_abs.path_join(file_name)

func _remove_if_present(path: String) -> void:
	if FileAccess.file_exists(path):
		DirAccess.remove_absolute(path)

func _first_command(commands: Array, type: String) -> Variant:
	for record: Variant in commands:
		if record is Dictionary:
			var command: Dictionary = record.get("command", {})
			if String(command.get("type", "")) == type:
				return record
	return null

func _commands_of_type(commands: Array, type: String) -> Array:
	var result: Array = []
	for record: Variant in commands:
		if record is Dictionary:
			var command: Dictionary = record.get("command", {})
			if String(command.get("type", "")) == type:
				result.append(record)
	return result

func _has_fixture_command(commands: Array) -> bool:
	for record: Variant in commands:
		if record is Dictionary:
			var command: Dictionary = record.get("command", {})
			if String(command.get("type", "")).begins_with("fixture_"):
				return true
	return false

func _commands_with_life(commands: Array, life_id: int) -> Array:
	var result: Array = []
	for record: Variant in commands:
		if record is Dictionary and int(record.get("life_id", -1)) == life_id:
			result.append(record)
	return result

func _has_rejection(rejections: Array, reason: String) -> bool:
	for record: Variant in rejections:
		if record is Dictionary and String(record.get("reason", "")) == reason:
			return true
	return false

func _acks_contain(acks: Array, reason: String) -> bool:
	for record: Variant in acks:
		if record is Dictionary and String(record.get("reason", "")) == reason:
			return true
	return false
