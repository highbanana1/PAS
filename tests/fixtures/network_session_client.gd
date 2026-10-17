extends SceneTree

## Real Godot client process for the Ticket 02A test. It joins the host over
## localhost, waits for the server-assigned identity, then sends a scripted
## gameplay envelope sequence covering forged identity, duplicates,
## regressions, stale epoch/life, and life 2. Those gameplay envelopes stay on
## the unreliable_ordered command channel. The life-change trigger and the
## finish/close handshake use a fixture-only reliable control node instead.
## Every wait is bounded, every step is logged, and the process always exits.

const SESSION_PATH := "res://scene/script/network/network_session.gd"
const CONTROL_PATH := "res://tests/fixtures/network_session_control.gd"

var _session
var _control
var _out_path := ""
var _log_path := ""
var _deadline_ms := 0
var _initial_identity: Dictionary = {}
var _final_identity: Dictionary = {}
var _acks: Array = []
var _sends: Array = []
var _life_change_requested := false
var _finish_requested := false
var _finish_acknowledged := false
var _error := ""

func _initialize() -> void:
	_run.call_deferred()

func _run() -> void:
	var args := _parse_args(OS.get_cmdline_user_args())
	_out_path = String(args.get("out", ""))
	_log_path = String(args.get("log", ""))
	var port := int(args.get("port", "0"))
	var epoch := int(args.get("epoch", "424242"))
	var max_wait := float(args.get("max-wait", "15"))
	_deadline_ms = Time.get_ticks_msec() + int(max_wait * 1000.0)
	_log("starting client fixture (port=%d max-wait=%.1fs)" % [port, max_wait])
	if _out_path.is_empty() or port <= 0:
		_error = "missing --out/--port"
		_finish(1)
		return
	var control_script = load(CONTROL_PATH)
	if control_script == null or not control_script.can_instantiate():
		_error = "fixture control module is missing"
		_finish(1)
		return
	_control = control_script.new()
	_control.name = "FixtureControl"
	_control.log_path = _log_path
	root.add_child(_control)
	_control.finish_acknowledged.connect(_on_finish_acknowledged)
	var session_script = load(SESSION_PATH)
	if session_script == null or not session_script.can_instantiate():
		_error = "NetworkSession module is missing"
		_finish(1)
		return
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
	await _run_scenario(epoch)

func _run_scenario(epoch: int) -> void:
	var valid_forged := await _send("valid_forged", {
		"type": "move",
		"direction": {"x": 1.0, "y": 0.0},
		"player_id": "player_999",
	})
	var duplicate := await _send("duplicate", {"type": "move", "direction": {"x": 0.0, "y": 1.0}}, 1)
	var higher := await _send("higher", {"type": "jump"}, 10)
	var regressed := await _send("regressed", {"type": "jump"}, 9)
	var stale_epoch := await _send("stale_epoch", {"type": "dash"}, 11, -1, epoch - 1)
	for result: Dictionary in [valid_forged, duplicate, higher, regressed, stale_epoch]:
		if not bool(result.get("wait_ok", false)):
			_error = "missing acknowledgement for " + String(result.get("label", "?"))
			_finish(1)
			return
	if not _request_life_change():
		_finish(1)
		return
	if not await _wait_for_life(2):
		_error = "client did not receive life id 2"
		_finish(1)
		return
	var stale_life := await _send("stale_life", {"type": "dash"}, 100, 1)
	var valid_life_two := await _send("valid_life_two", {"type": "move"}, 101, 2)
	for result: Dictionary in [stale_life, valid_life_two]:
		if not bool(result.get("wait_ok", false)):
			_error = "missing acknowledgement for " + String(result.get("label", "?"))
			_finish(1)
			return
	# The final valid gameplay command is acknowledged before this reliable
	# control message, so the host can verify it and then close safely.
	if not _request_finish():
		_finish(1)
		return
	if not await _wait_for_finish_ack():
		_error = "client did not receive the reliable finish acknowledgement"
		_finish(1)
		return
	_final_identity = _session.get_local_identity()
	_finish(0)

func _send(label: String, command: Dictionary, sequence: int = -1, life_id: int = -1, epoch: int = -1) -> Dictionary:
	var expected := _acks.size() + 1
	var sent: int = _session.send_command(command, sequence, life_id, epoch)
	_sends.append({"label": label, "sequence": sent})
	if sent <= 0:
		_error = "send_command failed for " + label
		_log("send failed: " + label)
		return {"label": label, "sent": sent, "ack": {}, "wait_ok": false}
	var wait_ok := await _wait_for_acks(expected)
	var ack: Dictionary = {}
	if _acks.size() >= expected:
		ack = _acks[expected - 1]
	_log("command %s seq=%d ack=%s" % [label, sent, "yes" if wait_ok else "timeout"])
	return {"label": label, "sent": sent, "ack": ack, "wait_ok": wait_ok}

func _request_life_change() -> bool:
	var request_error: int = _control.request_life_change()
	_life_change_requested = request_error == OK
	_log("reliable life-change control request: %s" % ("sent" if _life_change_requested else "error %d" % request_error))
	if not _life_change_requested:
		_error = "life-change control request failed with error %d" % request_error
	return _life_change_requested

func _request_finish() -> bool:
	var request_error: int = _control.request_finish()
	_finish_requested = request_error == OK
	_log("reliable finish control request: %s" % ("sent" if _finish_requested else "error %d" % request_error))
	if not _finish_requested:
		_error = "finish control request failed with error %d" % request_error
	return _finish_requested

func _wait_for_finish_ack() -> bool:
	while Time.get_ticks_msec() < _deadline_ms:
		if _finish_acknowledged:
			_log("reliable finish acknowledgement received")
			return true
		await create_timer(0.02).timeout
	_log("timed out waiting for the reliable finish acknowledgement")
	return _finish_acknowledged

func _on_finish_acknowledged() -> void:
	_finish_acknowledged = true

func _wait_for_identity() -> bool:
	while Time.get_ticks_msec() < _deadline_ms:
		var identity: Dictionary = _session.get_local_identity()
		if not identity.is_empty():
			return true
		if not _session.is_active():
			return false
		await create_timer(0.02).timeout
	return false

func _wait_for_acks(target: int) -> bool:
	while Time.get_ticks_msec() < _deadline_ms:
		_acks.append_array(_session.drain_command_results())
		if _acks.size() >= target:
			return true
		await create_timer(0.02).timeout
	_acks.append_array(_session.drain_command_results())
	return _acks.size() >= target

func _wait_for_life(expected: int) -> bool:
	while Time.get_ticks_msec() < _deadline_ms:
		var identity: Dictionary = _session.get_local_identity()
		if int(identity.get("life_id", -1)) == expected:
			_log("life id %d observed" % expected)
			return true
		await create_timer(0.02).timeout
	_log("timed out waiting for life id %d" % expected)
	return false

func _finish(code: int) -> void:
	if _final_identity.is_empty() and _session != null:
		_final_identity = _session.get_local_identity()
	var data := {
		"ok": code == 0 and _error.is_empty(),
		"error": _error,
		"server_port": _session.get_port() if _session != null else 0,
		"initial_identity": _initial_identity,
		"final_identity": _final_identity,
		"sends": _sends,
		"acks": _acks,
		"life_change_requested": _life_change_requested,
		"finish_requested": _finish_requested,
		"finish_acknowledged": _finish_acknowledged,
		"pid": OS.get_process_id(),
	}
	_log("finishing: ok=%s error=%s acks=%d" % [code == 0 and _error.is_empty(), _error, _acks.size()])
	_write_json(_out_path, data)
	if _session != null:
		_session.stop()
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
