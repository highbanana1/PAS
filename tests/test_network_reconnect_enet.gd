extends SceneTree

## Real ENet handshake/continuity test for Ticket 06. Four child processes run
## against the same host: initial join, invalid credential, and valid resume.
const FIXTURE := "res://tests/fixtures/network_reconnect_peer.gd"
var failures: Array[String] = []
var pids: Array[int] = []
var folder: String

func _initialize() -> void:
	run.call_deferred()

func check(ok: bool, label: String) -> void:
	print(("PASS: " if ok else "FAIL: ") + label)
	if not ok: failures.append(label)

func read(name: String) -> Dictionary:
	var target := folder.path_join(name)
	if not FileAccess.file_exists(target): return {}
	var value: Variant = JSON.parse_string(FileAccess.get_file_as_string(target))
	return value if value is Dictionary else {}

func wait_for(name: String, milliseconds: int = 9000) -> bool:
	var until := Time.get_ticks_msec() + milliseconds
	while Time.get_ticks_msec() < until:
		if not read(name).is_empty(): return true
		await create_timer(0.05).timeout
	return not read(name).is_empty()

func launch(role: String) -> void:
	var pid := OS.create_process(OS.get_executable_path(), [
		"--headless", "--log-file", folder.path_join(role + ".log"),
		"--path", ProjectSettings.globalize_path("res://"),
		"--script", FIXTURE, "--", role, folder,
	], false)
	pids.append(pid)
	check(pid > 0, "Start real ENet " + role)

func run() -> void:
	folder = OS.get_temp_dir().path_join("pas-reconnect-%d-%d" % [OS.get_process_id(), Time.get_ticks_usec()])
	DirAccess.make_dir_recursive_absolute(folder)
	launch("host")
	var host_ready: bool = await wait_for("ready.json", 6000)
	check(host_ready, "Host opens a two-seat room")
	if host_ready:
		launch("initial")
		var first_ready: bool = await wait_for("first.json", 8500)
		var offline: bool = await wait_for("left.json", 8500)
		check(first_ready and offline, "First client joins then disconnects")
		if first_ready and offline:
			launch("intruder")
			var intruder_ready: bool = await wait_for("intruder_final.json", 6500)
			check(intruder_ready, "Invalid resume attempt finishes")
			if intruder_ready:
				await create_timer(0.3).timeout
				launch("resume")
				check(await wait_for("resume_final.json", 9000), "Valid resume attempt finishes")
				check(await wait_for("host_final.json", 4000), "Host reports final reservation state")

	var first: Dictionary = read("first.json")
	var identity: Dictionary = first.get("identity", {})
	var left: Dictionary = read("left.json")
	var intruder: Dictionary = read("intruder_final.json")
	var resumed: Dictionary = read("resume_final.json")
	var host: Dictionary = read("host_final.json")
	var resumed_signal: Dictionary = read("resumed_signal.json")
	check(String(identity.get("reconnect_token", "")).length() == 64,
		"First client receives a private 256-bit reconnect credential")
	check(bool(left.get("reserved", false)) and bool(left.get("actor_retained", false))
		and int(left.get("occupied", -1)) == 2,
		"Disconnect keeps the actor and counts its reserved seat")
	check(bool(intruder.get("rejected", false))
		and String(intruder.get("reason", "")) == "invalid_reconnect_credential"
		and bool(intruder.get("no_identity", false)),
		"Forged credential cannot claim the retained actor")
	check(bool(resumed.get("same_player", false)) and bool(resumed.get("token_rotated", false))
		and int(resumed.get("baseline_tick", -1)) > int(first.get("baseline_tick", 999999)),
		"Valid reconnect preserves the player identity and rotates the credential")
	check(is_equal_approx(float(resumed.get("health", -1.0)), 120.0),
		"Reconnect baseline contains current host health, not a stale pre-disconnect copy")
	check(bool(resumed_signal.get("actor_retained", false)) and bool(host.get("online", false))
		and not bool(host.get("reserved", true)) and int(host.get("occupied", -1)) == 2,
		"Host resumes the same actor and releases the reservation")
	check(read("host_error.json").is_empty() and read("initial_error.json").is_empty()
		and read("resume_error.json").is_empty(), "No fixture setup failed")
	var until := Time.get_ticks_msec() + 3000
	while pids.any(func(pid: int) -> bool: return OS.is_process_running(pid)) \
			and Time.get_ticks_msec() < until:
		await create_timer(0.05).timeout
	for pid in pids:
		if OS.is_process_running(pid): OS.kill(pid)
		check(not OS.is_process_running(pid), "Fixture process exited")
	for role in ["host", "initial", "intruder", "resume"]:
		var target := folder.path_join(role + ".log")
		var output := FileAccess.get_file_as_string(target) if FileAccess.file_exists(target) else "missing"
		check(output != "missing" and not output.contains("SCRIPT ERROR")
			and not output.contains("Parse Error"), role + " has no script error")
	print("ARTIFACTS: ", folder)
	print("RESULT: ", failures.size(), " failures")
	quit(0 if failures.is_empty() else 1)
