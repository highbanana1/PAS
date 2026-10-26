extends SceneTree

# Real two-process ENet test for Ticket 04. The host owns sword/guard/death/item
# outcomes; the client only submits intent and observes the authoritative
# replica. Guard depletion and the five-second respawn are accelerated through
# the same fixed authority clock to keep the test bounded.

var failures: Array[String] = []
var pids: Array[int] = []
var folder: String

func _initialize() -> void:
	run.call_deferred()

func check(ok: bool, label: String) -> void:
	print(("PASS: " if ok else "FAIL: ") + label)
	if not ok:
		failures.append(label)

func read(name: String) -> Dictionary:
	var path := folder.path_join(name)
	if not FileAccess.file_exists(path):
		return {}
	var value: Variant = JSON.parse_string(FileAccess.get_file_as_string(path))
	return value if value is Dictionary else {}

func launch(role: String) -> void:
	var pid := OS.create_process(OS.get_executable_path(), [
		"--headless",
		"--log-file", folder.path_join(role + ".log"),
		"--path", ProjectSettings.globalize_path("res://"),
		"--script", "res://tests/fixtures/network_melee_peer.gd",
		"--", role, folder,
	], false)
	pids.append(pid)
	check(pid > 0, "Launch real ENet " + role)

func run() -> void:
	folder = OS.get_temp_dir().path_join("pas-melee-%d-%d" % [OS.get_process_id(), Time.get_ticks_usec()])
	DirAccess.make_dir_recursive_absolute(folder)
	launch("host")
	var deadline := Time.get_ticks_msec() + 6000
	while read("ready.json").is_empty() and Time.get_ticks_msec() < deadline:
		await create_timer(0.05).timeout
	check(not read("ready.json").is_empty(), "Host listens on an ephemeral port")
	if read("ready.json").is_empty():
		await finish()
		return
	launch("client")
	deadline = Time.get_ticks_msec() + 24000
	while (read("host_final.json").is_empty() or read("client_final.json").is_empty()) \
			and Time.get_ticks_msec() < deadline:
		await create_timer(0.05).timeout
	var host := read("host_final.json")
	var client := read("client_final.json")
	check(not host.is_empty(), "Host produced a final observation")
	check(not client.is_empty(), "Client produced a final observation")
	if not host.is_empty():
		check(bool(host.get("sword_hit", false)), "Real client sword command damaged the host exactly once")
		check(int(host.get("host_health_after_sword", 0)) == 148, "Sword hit preserves the existing two damage")
		check(bool(host.get("block_raised", false)), "Client guard intent reached the host authority")
		check(float(host.get("block_health", 0.0)) == 150.0, "Directional guard blocked the melee hit")
		check(float(host.get("block_guard_value", 100.0)) < 85.0, "Successful block spent the twenty-point guard cost")
		check(bool(host.get("block_observed", false)), "Client converged on the blocked guard state")
		check(bool(host.get("depleted_exhausted", false)) and not bool(host.get("depleted_guarding", true)), "Ten seconds of guard drain exhausted and lowered guard")
		check(bool(host.get("mid_exhausted", false)) and not bool(host.get("mid_guarding", true)), "Exhaustion lock survives partial recovery")
		check(float(host.get("mid_value", 0.0)) > 20.0 and float(host.get("mid_value", 0.0)) < 85.0, "Partial recovery is bounded below full")
		check(is_equal_approx(float(host.get("full_value", 0.0)), 100.0) and not bool(host.get("full_exhausted", true)), "Full recovery restores the meter and clears exhaustion")
		check(bool(host.get("recovered_guarding", false)), "Guard is usable again only after full recovery")
		check(bool(host.get("items_granted", false)), "Client received the stable two-item backpack checkpoint")
		check(int(host.get("health_item_id", 0)) > 0 and int(host.get("jump_item_id", 0)) > 0, "Items have host-stable ids")
		var item_checkpoint: Dictionary = host.get("item_checkpoint", {})
		var item_map: Dictionary = item_checkpoint.get("items", {})
		check(item_map.size() == 2, "Item checkpoint contains exactly the two granted items")
		var health_item: Dictionary = item_map.get(str(int(host.get("health_item_id", 0))), {})
		check(String(health_item.get("type", "")) == "health" and is_equal_approx(float(health_item.get("remaining", 0.0)), 12.0), "Health item keeps its existing reserve")
		for forbidden in ["icon", "holder", "texture", "resource", "rid", "instance_id"]:
			check(not health_item.has(forbidden), "Item checkpoint omits " + forbidden)
		check(bool(host.get("death_dead", false)), "Authoritative sword swing killed the client actor")
		check(int(host.get("death_life", 0)) == 1, "Death is recorded on the first life")
		check(int(host.get("drop_count", 0)) == 2, "Death dropped exactly the two backpack items")
		check(bool(host.get("drop_owner_empty", false)), "Dropped items lost their old owner")
		check(int(host.get("after_dead_count", 0)) == 2, "Repeated dead ticks did not duplicate the drop")
		check(bool(host.get("world_kept_running", false)), "Another player keeps moving while the client is dead")
		check(bool(host.get("respawned", false)), "Five-second authority clock respawned the client")
		check(int(host.get("respawn_life", 0)) == 2, "Respawn advanced the stable client life id")
		check(float(host.get("respawn_health", 0.0)) == 150.0, "Respawn restored five health cells")
		var respawn_guard: Dictionary = host.get("respawn_guard", {})
		check(float(respawn_guard.get("value", 0.0)) == 100.0 and not bool(respawn_guard.get("exhausted", true)), "Respawn reset guard to full")
		check(bool(host.get("client_respawn_seen", false)), "Client converged on the respawned five-cell life")
		check(bool(host.get("host_pickup_won", false)), "Host-selected pickup winner holds the item")
		check(String(host.get("pickup_owner", "")) == String(host.get("host_id", "")), "Pickup owner is the host player id")
		check(int(host.get("pickup_count", 0)) == 2, "Competing and duplicate pickup requests did not duplicate items")
		check(bool(host.get("client_pickup_attempted", false)), "Client submitted the competing pickup request")
		check(bool(host.get("client_item_owner", false)), "Client converged on the host-selected item owner")
	if not client.is_empty():
		check(float(client.get("own_health", 0.0)) == 150.0 and not bool(client.get("own_dead", true)), "Client final snapshot is alive at five cells")
		check(int(client.get("own_life_id", 0)) == 2, "Client final snapshot carries the new life id")
		var guard: Dictionary = client.get("guard", {})
		check(float(guard.get("value", 0.0)) >= 0.0, "Client final guard checkpoint is valid")
		check(int(client.get("items", {}).size()) == 2, "Client final item checkpoint preserves both items")
		check(bool(client.get("pickup_attempted", false)), "Client attempted the losing pickup")
	check(read("host_error.json").is_empty() and read("client_error.json").is_empty(), "No fixture timeout")
	await finish()

func finish() -> void:
	var exit_deadline := Time.get_ticks_msec() + 4000
	while pids.any(func(pid: int) -> bool: return OS.is_process_running(pid)) \
			and Time.get_ticks_msec() < exit_deadline:
		await create_timer(0.05).timeout
	for index in range(pids.size()):
		var pid := pids[index]
		var process_role := "host" if index == 0 else "client"
		check(not OS.is_process_running(pid), process_role + " exits naturally after final handshake")
		if not OS.is_process_running(pid):
			check(OS.get_process_exit_code(pid) == 0, process_role + " process exits successfully")
		else:
			OS.kill(pid)
	for role in ["host", "client"]:
		var log_path := folder.path_join(role + ".log")
		var logs := FileAccess.get_file_as_string(log_path) if FileAccess.file_exists(log_path) else "missing log"
		check(logs != "missing log" and not logs.contains("SCRIPT ERROR") and not logs.contains("Parse Error"), role + " has no script or parse errors")
	print("ARTIFACTS: ", folder)
	print("RESULT: ", failures.size(), " failures")
	quit(0 if failures.is_empty() else 1)
