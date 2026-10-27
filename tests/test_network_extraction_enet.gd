extends SceneTree

var failures: Array[String] = []
var pids: Array[int] = []
var folder: String

func _initialize() -> void:
	run.call_deferred()

func check(ok: bool, label: String) -> void:
	print(("PASS: " if ok else "FAIL: ") + label)
	if not ok: failures.append(label)

func read(name: String) -> Dictionary:
	var path := folder.path_join(name)
	var value: Variant = JSON.parse_string(FileAccess.get_file_as_string(path)) if FileAccess.file_exists(path) else null
	return value if value is Dictionary else {}

func launch(role: String) -> void:
	var pid := OS.create_process(OS.get_executable_path(), [
		"--headless", "--log-file", folder.path_join(role + ".log"),
		"--path", ProjectSettings.globalize_path("res://"),
		"--script", "res://tests/fixtures/network_extraction_peer.gd", "--", role, folder,
	], false)
	pids.append(pid)
	check(pid > 0, "Start real ENet " + role)

func run() -> void:
	folder = OS.get_temp_dir().path_join("pas-extraction-%d-%d" % [OS.get_process_id(), Time.get_ticks_usec()])
	DirAccess.make_dir_recursive_absolute(folder)
	launch("host")
	var deadline := Time.get_ticks_msec() + 6000
	while read("ready.json").is_empty() and Time.get_ticks_msec() < deadline:
		await create_timer(0.05).timeout
	check(not read("ready.json").is_empty(), "Host opened a LAN session")
	if not read("ready.json").is_empty(): launch("client")
	deadline = Time.get_ticks_msec() + 20000
	while (read("host_final.json").is_empty() or read("client_final.json").is_empty()) \
			and Time.get_ticks_msec() < deadline:
		await create_timer(0.05).timeout
	var host := read("host_final.json")
	var client := read("client_final.json")
	check(bool(host.get("got_client", false)) and String(host.get("star_state", "")) == "CONSUMED",
		"Host consumed exactly the delivered star")
	check(bool(host.get("extracted", false)) and bool(host.get("host_still_active", false)),
		"Winner spectates while the host keeps playing")
	check(bool(client.get("pickup", false)) and bool(client.get("carried", false))
		and bool(client.get("delivery", false)), "Real client picked and delivered through validated commands")
	check(bool(client.get("extracted", false)) and bool(client.get("spectating", false))
		and bool(client.get("blocked_move", false)), "Client converged on spectator and cannot rejoin combat")
	check(read("host_error.json").is_empty() and read("client_error.json").is_empty(), "No fixture setup failed")
	deadline = Time.get_ticks_msec() + 3000
	while pids.any(func(pid: int) -> bool: return OS.is_process_running(pid)) and Time.get_ticks_msec() < deadline:
		await create_timer(0.05).timeout
	for pid in pids:
		check(not OS.is_process_running(pid), "Fixture process exited")
		if OS.is_process_running(pid): OS.kill(pid)
	for role in ["host", "client"]:
		var path := folder.path_join(role + ".log")
		var output := FileAccess.get_file_as_string(path) if FileAccess.file_exists(path) else "missing"
		check(output != "missing" and not output.contains("SCRIPT ERROR")
			and not output.contains("Parse Error"), role + " has no script error")
	print("ARTIFACTS: ", folder)
	print("RESULT: ", failures.size(), " failures")
	quit(0 if failures.is_empty() else 1)
