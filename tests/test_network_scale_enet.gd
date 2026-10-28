extends SceneTree

## Ticket 08 real localhost ENet load seam: sixteen occupied seats receive
## fragmented movement ticks, and the seventeenth connection is rejected.
const FIXTURE := "res://tests/fixtures/network_scale_peer.gd"
const MAX_CLIENT_LAG_TICKS := 120
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

func wait_for(name: String, timeout_msec: int) -> bool:
	var deadline := Time.get_ticks_msec() + timeout_msec
	while Time.get_ticks_msec() < deadline:
		if not read(name).is_empty(): return true
		await create_timer(0.05).timeout
	return not read(name).is_empty()

func launch(role: String, index: int = 0) -> void:
	var label := role + ("_%02d" % index if role == "client" else "")
	var pid := OS.create_process(OS.get_executable_path(), ["--headless", "--log-file",
		folder.path_join(label + ".log"), "--path", ProjectSettings.globalize_path("res://"),
		"--script", FIXTURE, "--", role, folder, str(index)], false)
	pids.append(pid)
	check(pid > 0, "Start real ENet " + label)

func run() -> void:
	var started := Time.get_ticks_msec()
	folder = OS.get_temp_dir().path_join("pas-ticket08-scale-%d-%d" % [OS.get_process_id(), Time.get_ticks_usec()])
	DirAccess.make_dir_recursive_absolute(folder)
	launch("host")
	var ready := await wait_for("ready.json", 6000)
	check(ready, "Host opens a sixteen-seat room")
	if ready:
		for index in range(1, 16): launch("client", index)
	var full := await wait_for("full.json", 14000)
	check(full and int(read("full.json").get("occupied", 0)) == 16,
		"Host reaches all sixteen occupied seats")
	if full: launch("overflow")
	var overflow := await wait_for("overflow.json", 8000)
	check(overflow and bool(read("overflow.json").get("ok", false)) \
		and String(read("overflow.json").get("reason", "")) == "room_full" \
		and bool(read("overflow.json").get("no_identity", false)),
		"Seventeenth peer is rejected without receiving an identity")
	for index in range(1, 16):
		var name := "client_%02d.json" % index
		var finished := await wait_for(name, 16000)
		var result: Dictionary = read(name)
		var host_tick := int(read("host_result.json").get("last_tick", -1))
		var client_tick := int(result.get("last_tick", -1))
		check(finished and bool(result.get("ok", false)) \
			and int(result.get("players", 0)) == 16 \
			and int(result.get("last_batch_players", 0)) == 16 \
			and client_tick >= host_tick - MAX_CLIENT_LAG_TICKS,
			"Client %02d converges an atomic sixteen-player tick" % index)
	var host_done := await wait_for("host_result.json", 10000)
	var host: Dictionary = read("host_result.json")
	var metrics: Dictionary = host.get("metrics", {})
	check(host_done and bool(host.get("ok", false)) and int(host.get("actors", 0)) == 16 \
		and int(host.get("players", 0)) == 16 and int(host.get("occupied", 0)) == 16,
		"Host retains all sixteen authoritative actors during the sample")
	check(int(metrics.get("snapshot_batches", 0)) > 0 \
		and int(metrics.get("snapshot_packets", 0)) > int(metrics.get("snapshot_batches", 0)) \
		and int(metrics.get("snapshot_max_packet_bytes", 999999)) <= 1200,
		"Movement snapshots are fragmented below the declared payload budget")
	check(int(metrics.get("combat_packets", 0)) > 0 \
		and int(metrics.get("combat_payload_bytes", 0)) > 0,
		"Reliable combat payload size and frequency are measured")
	var elapsed := float(Time.get_ticks_msec() - started) / 1000.0
	print("LOAD SAMPLE: os=%s processors=%d elapsed=%.2fs metrics=%s artifacts=%s" % [
		String(host.get("os", "unknown")), int(host.get("processor_count", 0)), elapsed,
		JSON.stringify(metrics), folder])
	for pid in pids:
		if OS.is_process_running(pid): OS.kill(pid)
	print("RESULT: ", failures.size(), " failures")
	quit(0 if failures.is_empty() else 1)
