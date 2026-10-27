extends SceneTree
var failures: Array[String] = []
var pids: Array[int] = []
var folder: String
func _initialize() -> void: run.call_deferred()
func check(ok: bool, label: String) -> void:
	print(("PASS: " if ok else "FAIL: ") + label)
	if not ok: failures.append(label)
func read(name: String) -> Dictionary:
	var path := folder.path_join(name)
	if not FileAccess.file_exists(path): return {}
	var data: Variant = JSON.parse_string(FileAccess.get_file_as_string(path))
	return data if data is Dictionary else {}
func launch(role: String) -> void:
	var pid := OS.create_process(OS.get_executable_path(), ["--headless","--log-file",folder.path_join(role + ".log"),"--path",ProjectSettings.globalize_path("res://"),"--script","res://tests/fixtures/network_shotgun_peer.gd","--",role,folder], false)
	pids.append(pid); check(pid > 0, "Launch real ENet " + role)
func run() -> void:
	folder = OS.get_temp_dir().path_join("pas-shotgun-%d-%d" % [OS.get_process_id(),Time.get_ticks_usec()])
	DirAccess.make_dir_recursive_absolute(folder)
	launch("host")
	var deadline := Time.get_ticks_msec()+6000
	while read("ready.json").is_empty() and Time.get_ticks_msec()<deadline: await create_timer(0.05).timeout
	check(not read("ready.json").is_empty(), "Host listens on ephemeral port")
	if not read("ready.json").is_empty():
		launch("client")
		deadline = Time.get_ticks_msec()+19000
		while read("client_final.json").is_empty() and Time.get_ticks_msec()<deadline: await create_timer(0.05).timeout
		var hit := read("host_hit.json"); var client_hit := read("client_hit.json")
		check(hit.get("health") == 22 and client_hit.get("health") == 22, "Both processes see five independent hits: 31 HP to 22")
		check(client_hit.get("stale_rejected",false) and client_hit.get("no_rollback",false), "Delayed baseline cannot roll back combat or health")
		if not hit.is_empty() and not client_hit.is_empty():
			check(hit.combat.projectiles.is_empty() and client_hit.combat.projectiles.is_empty(), "Both ends remove impacted pellets")
			var client_shots: Array = client_hit.shots
			check(client_shots.size() == 1 and client_shots[0].pellets.size() == 5, "Client receives same complete five pellet shot event")
			var host_shots: Array = hit.combat.events.filter(func(e): return e.get("type") == "shot_spawned")
			check(host_shots == client_shots, "Authoritative shot geometry and identity match across real ENet")
		var final_host := read("host_final.json"); var final_client := read("client_final.json")
		check(final_host.get("dead",false) and final_client.get("dead",false), "Death is consistent across processes")
		check(final_host.get("health") == 0 and final_client.get("health") == 0, "Both peers settle at zero HP")
		if not final_host.is_empty() and not final_client.is_empty():
			check(final_host.combat.projectiles.is_empty() and final_client.combat.projectiles.is_empty(), "Lethal shot despawns on both peers")
		check(read("host_error.json").is_empty() and read("client_error.json").is_empty(), "No fixture timeout")
	var exit_deadline := Time.get_ticks_msec() + 3000
	while pids.any(func(pid: int): return OS.is_process_running(pid)) and Time.get_ticks_msec() < exit_deadline:
		await create_timer(0.05).timeout
	for index in range(pids.size()):
		var pid := pids[index]
		var process_role := "host" if index == 0 else "client"
		check(not OS.is_process_running(pid), process_role + " exits naturally after final handshake")
		if not OS.is_process_running(pid):
			check(OS.get_process_exit_code(pid) == 0, process_role + " process exits successfully")
		else:
			OS.kill(pid)
	for role in ["host","client"]:
		var log_path := folder.path_join(role + ".log")
		var logs := FileAccess.get_file_as_string(log_path) if FileAccess.file_exists(log_path) else "missing log"
		check(logs != "missing log" and not logs.contains("SCRIPT ERROR") and not logs.contains("Parse Error"), role + " has no script or parse errors")
	print("ARTIFACTS: ",folder)
	print("RESULT: ",failures.size()," failures")
	quit(0 if failures.is_empty() else 1)

