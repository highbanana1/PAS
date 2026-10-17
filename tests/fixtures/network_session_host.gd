extends SceneTree

## Real Godot process that hosts a NetworkSession for the Ticket 02A test.
## It binds an ephemeral UDP port, publishes that port, records the client's
## authoritative identity, advances one life id when asked, and writes an
## observable result before exiting. The life-change trigger and the
## finish/close handshake arrive on a fixture-only reliable control node, never
## as gameplay commands. Every wait is bounded and every step is logged.

const SESSION_PATH := "res://scene/script/network/network_session.gd"
const CONTROL_PATH := "res://tests/fixtures/network_session_control.gd"
const FINAL_SEQUENCE: int = 101
const FINAL_LIFE_ID: int = 2
const FINISH_GRACE_MS: int = 3000

var _session
var _control
var _out_path := ""
var _ready_path := ""
var _log_path := ""
var _deadline_ms := 0
var _client_identity: Dictionary = {}
var _mapped_player_id := ""
var _reverse_peer_id := 0
var _commands: Array = []
var _rejections: Array = []
var _life_change_requested := false
var _life_change_pending := false
var _life_changed := false
var _life_change_ok := false
var _seen_command_count := 0
var _seen_rejection_count := 0
var _finish_requested := false
var _finish_verified := false
var _finish_ack_sent := false
var _finish_mismatch_logged := false
var _finish_at := -1
var _final_sequence := -1
var _final_life_id := -1
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
	var max_wait := float(args.get("max-wait", "15"))
	_deadline_ms = Time.get_ticks_msec() + int(max_wait * 1000.0)
	_log("starting host fixture (max-wait=%.1fs)" % max_wait)
	if _out_path.is_empty() or _ready_path.is_empty():
		_error = "missing --out/--ready"
		_fail_early(1)
		return
	var control_script = load(CONTROL_PATH)
	if control_script == null or not control_script.can_instantiate():
		_error = "fixture control module is missing"
		_fail_early(1)
		return
	_control = control_script.new()
	_control.name = "FixtureControl"
	_control.log_path = _log_path
	root.add_child(_control)
	_control.life_change_requested.connect(_on_life_change_requested)
	_control.finish_requested.connect(_on_finish_requested)
	var session_script = load(SESSION_PATH)
	if session_script == null or not session_script.can_instantiate():
		_error = "NetworkSession module is missing"
		_fail_early(1)
		return
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
	_write_json(_ready_path, {
		"ok": true,
		"port": _session.get_port(),
		"epoch": _session.get_match_epoch(),
		"pid": OS.get_process_id(),
	})
	_log("listening on ephemeral port %d epoch %d" % [_session.get_port(), _session.get_match_epoch()])
	await _run_session()

func _run_session() -> void:
	while Time.get_ticks_msec() < _deadline_ms:
		_drain_session()
		if _client_identity.is_empty() and _session.get_player_count() > 1:
			_capture_client_identity()
		_try_life_change()
		if _finish_requested and not _finish_verified:
			_try_verify_finish()
		if _finish_at >= 0:
			# Stay up until the reliable finish acknowledgement has reached the
			# client (it disconnects after receiving it). The grace period is a
			# hard bound if the client disappears instead.
			if _session.get_player_count() < 2 or Time.get_ticks_msec() - _finish_at > FINISH_GRACE_MS:
				break
		await create_timer(0.02).timeout
	_drain_session()
	if _client_identity.is_empty() and _session.get_player_count() > 1:
		_capture_client_identity()
	_try_life_change()
	var ok := false
	if _finish_verified and not _finish_ack_sent and _error.is_empty():
		_error = "host could not acknowledge the finish handshake"
		_exit_code = 1
	if not _finish_requested and _error.is_empty():
		_error = "host timed out waiting for the finish control signal"
		_exit_code = 1
	elif _finish_requested and not _finish_verified and _error.is_empty():
		_error = "host could not verify the final valid gameplay command before timeout"
		_exit_code = 1
	if _life_change_pending and not _life_changed and _error.is_empty():
		_error = "host could not apply the life-change control signal before timeout"
		_exit_code = 1
	ok = _finish_verified and _error.is_empty()
	_log("finishing: verified=%s ack_sent=%s error=%s" % [_finish_verified, _finish_ack_sent, _error])
	_write_result(ok)
	_session.stop()
	quit(_exit_code)

func _drain_session() -> void:
	var new_commands: Array = _session.drain_commands()
	_commands.append_array(new_commands)
	for index in range(_seen_command_count, _commands.size()):
		_handle_accepted_command(_commands[index])
	_seen_command_count = _commands.size()
	var new_rejections: Array = _session.drain_rejections()
	_rejections.append_array(new_rejections)
	for index in range(_seen_rejection_count, _rejections.size()):
		var rejected: Dictionary = _rejections[index]
		_log("rejected seq=%d type=%s reason=%s" % [
			int(rejected.get("sequence", -1)),
			String(rejected.get("command", {}).get("type", "")),
			String(rejected.get("reason", "")),
		])
	_seen_rejection_count = _rejections.size()

func _handle_accepted_command(record: Dictionary) -> void:
	var peer_id := int(record.get("peer_id", 0))
	if _client_identity.is_empty() and peer_id > 1:
		_remember_identity(peer_id)
	var command: Dictionary = record.get("command", {})
	_log("accepted seq=%d life=%d type=%s from peer=%d" % [
		int(record.get("sequence", -1)),
		int(record.get("life_id", -1)),
		String(command.get("type", "")),
		peer_id,
	])

func _try_life_change() -> void:
	if not _life_change_pending or _life_changed:
		return
	if _mapped_player_id.is_empty():
		_capture_client_identity()
	if _mapped_player_id.is_empty():
		return
	_life_change_pending = false
	_life_changed = true
	_life_change_ok = _session.set_player_life(StringName(_mapped_player_id), FINAL_LIFE_ID)
	_log("life-change control applied to %s: ok=%s" % [_mapped_player_id, _life_change_ok])
	if not _life_change_ok:
		_error = "set_player_life failed"
		_exit_code = 1

func _try_verify_finish() -> void:
	if _commands.is_empty():
		return
	var last: Dictionary = _commands[_commands.size() - 1]
	var command: Dictionary = last.get("command", {})
	var sequence := int(last.get("sequence", -1))
	var life_id := int(last.get("life_id", -1))
	var command_type := String(command.get("type", ""))
	if sequence != FINAL_SEQUENCE or life_id != FINAL_LIFE_ID or command_type != "move":
		if not _finish_mismatch_logged:
			_finish_mismatch_logged = true
			_log("finish waiting for final command: last seq=%d life=%d type=%s" % [sequence, life_id, command_type])
		return
	_finish_verified = true
	_final_sequence = sequence
	_final_life_id = life_id
	_finish_at = Time.get_ticks_msec()
	var ack_error: int = _control.acknowledge_finish(int(_client_identity.get("peer_id", 0)))
	_finish_ack_sent = ack_error == OK
	_log("finish verified after final command seq=%d life=%d; reliable ack=%s" % [
		sequence,
		life_id,
		"sent" if _finish_ack_sent else "error %d" % ack_error,
	])

func _on_life_change_requested() -> void:
	if _life_change_requested:
		return
	_life_change_requested = true
	_life_change_pending = true
	_log("reliable life-change control received")
	_try_life_change()

func _on_finish_requested() -> void:
	if _finish_requested:
		return
	_finish_requested = true
	_log("reliable finish control received")
	_try_verify_finish()

func _capture_client_identity() -> void:
	for record: Variant in _commands:
		if record is Dictionary:
			var peer_id := int(record.get("peer_id", 0))
			if peer_id > 1:
				_remember_identity(peer_id)
				if not _client_identity.is_empty():
					return

func _remember_identity(peer_id: int) -> void:
	_client_identity = _session.get_identity_for_peer(peer_id)
	if _client_identity.is_empty():
		return
	_mapped_player_id = String(_session.get_player_id_for_peer(peer_id))
	_reverse_peer_id = int(_session.get_peer_id_for_player(StringName(_mapped_player_id)))
	_log("mapped peer %d to %s (reverse=%d)" % [peer_id, _mapped_player_id, _reverse_peer_id])

func _write_result(ok: bool) -> void:
	var data := {
		"ok": ok,
		"error": _error,
		"port": _session.get_port(),
		"match_epoch": _session.get_match_epoch(),
		"local_identity": _session.get_local_identity(),
		"client_identity": _client_identity,
		"mapped_player_id": _mapped_player_id,
		"reverse_peer_id": _reverse_peer_id,
		"player_count": _session.get_player_count(),
		"max_seats": _session.get_max_seats(),
		"remote_capacity": _session.get_remote_capacity(),
		"life_change_requested": _life_change_requested,
		"life_change_ok": _life_change_ok,
		"finish_requested": _finish_requested,
		"finish_verified": _finish_verified,
		"finish_ack_sent": _finish_ack_sent,
		"final_command_sequence": _final_sequence,
		"final_command_life_id": _final_life_id,
		"commands": _commands,
		"rejections": _rejections,
	}
	_write_json(_out_path, data)

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
