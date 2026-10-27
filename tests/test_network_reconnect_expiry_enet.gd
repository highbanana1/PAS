extends SceneTree

## Real 30-second reservation expiry, with host-owned star/item cleanup.
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

func wait_for(name: String, milliseconds: int) -> bool:
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
	folder = OS.get_temp_dir().path_join("pas-reconnect-expiry-%d-%d" % [OS.get_process_id(), Time.get_ticks_usec()])
	DirAccess.make_dir_recursive_absolute(folder)
	launch("host_expiry")
	var ready: bool = await wait_for("ready.json", 6000)
	check(ready, "Host opens a two-seat room")
	if ready: launch("initial")
	var joined: bool = await wait_for("first.json", 9000)
	var left: bool = await wait_for("expiry_left.json", 9000)
	check(joined and left, "Client receives credential then disconnects")
	var elapsed: int = -1
	if joined and left:
		var started := Time.get_ticks_msec()
		var expired: bool = await wait_for("expiry_state.json", 36000)
		elapsed = Time.get_ticks_msec() - started
		check(expired, "Reservation expires while real Godot processes keep running")
		if expired:
			launch("stale")
			check(await wait_for("stale_final.json", 7000), "Old credential retry finishes")
			if await wait_for("expiry_host_final.json", 4000):
				launch("replacement")
				check(await wait_for("replacement_final.json", 9000), "Fresh client joins the released seat")
				check(await wait_for("replacement_host_final.json", 4000), "Host audits replacement identity")
			else:
				check(false, "Host finishes expiry audit")

	var left_state: Dictionary = read("expiry_left.json")
	var expired_state: Dictionary = read("expiry_state.json")
	var stale: Dictionary = read("stale_final.json")
	var host: Dictionary = read("expiry_host_final.json")
	var first_id := String(read("first.json").get("identity", {}).get("player_id", ""))
	var replacement: Dictionary = read("replacement_final.json")
	var replacement_host: Dictionary = read("replacement_host_final.json")
	var next_id := String(replacement.get("player_id", ""))
	var old_sequence := int(first_id.trim_prefix("player_"))
	var next_sequence := int(next_id.trim_prefix("player_"))
	check(bool(left_state.get("reserved", false)) and bool(left_state.get("actor_retained", false))
		and int(left_state.get("occupied", -1)) == 2,
		"Disconnected actor stays in combat and holds the reserved seat")
	check(elapsed >= 29000 and elapsed <= 36000,
		"Default reservation persists for about thirty seconds")
	check(bool(expired_state.get("expired", false))
		and bool(expired_state.get("same_player", false))
		and int(expired_state.get("event_count", -1)) == 1,
		"Expiry signal fires exactly once for the original player")
	check(bool(expired_state.get("player_removed", false))
		and int(expired_state.get("occupied", -1)) == 1,
		"Expiry removes the actor and releases its seat")
	check(bool(expired_state.get("star_free", false))
		and bool(expired_state.get("point_free", false))
		and bool(expired_state.get("item_free", false)),
		"Expiry drops star and item once and frees the extraction point")
	check(bool(stale.get("rejected", false))
		and String(stale.get("reason", "")) == "invalid_reconnect_credential"
		and bool(stale.get("no_identity", false)),
		"Expired credential cannot restore the old player")
	check(int(host.get("event_count", -1)) == 1
		and bool(host.get("no_duplicate_drop", false))
		and int(host.get("occupied", -1)) == 1,
		"Later ticks do not repeat the expiry signal or drops")
	check(int(replacement.get("seat", -1)) == 2
		and int(replacement_host.get("new_seat", -1)) == 2
		and int(replacement_host.get("occupied", -1)) == 2,
		"Fresh player reuses released seat two")
	check(first_id.begins_with("player_") and next_id.begins_with("player_")
		and next_id != first_id and next_sequence > old_sequence
		and String(replacement_host.get("old_player_id", "")) == first_id
		and String(replacement_host.get("new_player_id", "")) == next_id,
		"Fresh player receives a distinct monotonic identity")
	check(bool(replacement.get("baseline_has_new", false))
		and bool(replacement.get("baseline_excludes_old", false))
		and bool(replacement_host.get("old_actor_absent", false))
		and bool(replacement_host.get("new_actor_bound", false))
		and bool(replacement_host.get("old_drop_unchanged", false)),
		"Fresh actor enters without reviving old actor or changing its drops")
	check(read("expiry_host_error.json").is_empty() and read("initial_error.json").is_empty(),
		"No fixture setup failed")
	check(read("replacement_error.json").is_empty(), "Replacement fixture setup succeeded")
	var until := Time.get_ticks_msec() + 3000
	while pids.any(func(pid: int) -> bool: return OS.is_process_running(pid)) \
			and Time.get_ticks_msec() < until:
		await create_timer(0.05).timeout
	for pid in pids:
		if OS.is_process_running(pid): OS.kill(pid)
		check(not OS.is_process_running(pid), "Fixture process exited")
	for role in ["host_expiry", "initial", "stale", "replacement"]:
		var target := folder.path_join(role + ".log")
		var output := FileAccess.get_file_as_string(target) if FileAccess.file_exists(target) else "missing"
		check(output != "missing" and not output.contains("SCRIPT ERROR")
			and not output.contains("Parse Error"), role + " has no script error")
	print("ARTIFACTS: ", folder)
	print("RESULT: ", failures.size(), " failures")
	quit(0 if failures.is_empty() else 1)
