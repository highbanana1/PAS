extends SceneTree

const Session = preload("res://scene/script/network/network_session.gd")
const Bridge = preload("res://scene/script/network/match_network_bridge.gd")
const Assembler = preload("res://scene/script/network/snapshot_chunk_assembler.gd")
const Actor = preload("res://tests/fixtures/network_combat_actor.gd")

var failures: Array[String] = []

func _initialize() -> void:
	run.call_deferred()

func check(ok: bool, label: String) -> void:
	print(("PASS: " if ok else "FAIL: ") + label)
	if not ok: failures.append(label)

func run() -> void:
	var session = Session.new()
	root.add_child(session)
	var bridge = Bridge.new()
	root.add_child(bridge)
	check(session.host(0, {"seats": 16, "match_epoch": 808808}) == OK \
		and bridge.configure(session), "Host creates the sixteen-seat scale seam")
	var actors: Array[Node] = []
	for index in range(16):
		var actor = Actor.new()
		actor.position = Vector2(index * 24.0, -index * 3.0)
		root.add_child(actor)
		actors.append(actor)
		check(bridge.bind_actor(StringName("player_%d" % (index + 1)), actor),
			"Bind scale actor %d" % (index + 1))
	bridge._send_snapshot()
	var complete: Dictionary = bridge.get_last_snapshot_batch()
	var fragments: Array[Dictionary] = bridge.get_last_snapshot_fragments()
	check(complete.get("players", {}).size() == 16,
		"Complete movement tick retains all sixteen stable player ids")
	for player_state: Dictionary in complete.get("players", {}).values():
		check(player_state.has("player_id") and player_state.has("tick") \
			and player_state.has("revision") and player_state.has("ack_sequence"),
			"Every movement record retains id, tick, revision and input acknowledgement")
	check(fragments.size() > 1, "Sixteen-player movement state is split across MTU-safe packets")
	for population in [1, 4, 8, 16]:
		var sample_players: Dictionary = {}
		for index in range(population):
			sample_players["player_%d" % (index + 1)] = complete.players["player_%d" % (index + 1)]
		var sample := {"match_epoch": complete.match_epoch, "server_tick": complete.server_tick,
			"players": sample_players}
		var sample_fragments: Array[Dictionary] = bridge._fragment_snapshot_batch(sample)
		var sample_bytes := 0
		for fragment: Dictionary in sample_fragments: sample_bytes += var_to_bytes(fragment).size()
		print("SNAPSHOT SAMPLE: players=%d raw_bytes=%d packets=%d wire_payload_bytes=%d" % [
			population, var_to_bytes(sample).size(), sample_fragments.size(), sample_bytes])
		check(not sample_fragments.is_empty(),
			"Population %d produces a measurable movement snapshot" % population)
	var fragment_players := 0
	for index in range(fragments.size()):
		var fragment: Dictionary = fragments[index]
		fragment_players += fragment.get("players", {}).size()
		check(var_to_bytes(fragment).size() <= int(Bridge.SNAPSHOT_PACKET_BUDGET_BYTES),
			"Fragment %d stays within the declared payload budget" % index)
		check(int(fragment.get("snapshot_chunk_index", -1)) == index \
			and int(fragment.get("snapshot_chunk_count", -1)) == fragments.size() \
			and int(fragment.get("snapshot_player_count", -1)) == 16,
			"Fragment %d carries an unambiguous tick manifest" % index)
	check(fragment_players == 16, "Fragment manifest contains every player exactly once")

	var assembler = Assembler.new()
	var first: Dictionary = assembler.push(fragments[0])
	check(not bool(first.get("complete", true)) \
		and String(first.get("reason", "")) == "fragment_pending",
		"An incomplete tick is never exposed as a complete world state")
	var final: Dictionary = {}
	for index in range(1, fragments.size()): final = assembler.push(fragments[index])
	check(bool(final.get("complete", false)) \
		and final.get("batch", {}).get("players", {}).size() == 16,
		"All fragments reassemble one atomic sixteen-player tick")

	var newer_batch := complete.duplicate(true)
	newer_batch["server_tick"] = int(complete.get("server_tick", 0)) + 3
	var newer: Array[Dictionary] = bridge._fragment_snapshot_batch(newer_batch)
	assembler.reset()
	assembler.push(fragments[0])
	var superseding: Dictionary = assembler.push(newer[0])
	check(String(superseding.get("reason", "")) == "fragment_pending",
		"A newer tick supersedes an incomplete older tick")
	var stale: Dictionary = assembler.push(fragments[fragments.size() - 1])
	check(String(stale.get("reason", "")) == "stale_fragment",
		"A late old fragment cannot mix into the newer tick")
	for index in range(1, newer.size()): final = assembler.push(newer[index])
	check(bool(final.get("complete", false)) \
		and int(final.get("batch", {}).get("server_tick", -1)) == int(newer_batch.server_tick),
		"The complete newer tick converges after the dropped old tick")

	var metrics: Dictionary = bridge.get_network_metrics()
	check(int(metrics.get("snapshot_batches", 0)) == 1 \
		and int(metrics.get("snapshot_packets", 0)) == fragments.size() \
		and int(metrics.get("snapshot_max_packet_bytes", 999999)) <= int(Bridge.SNAPSHOT_PACKET_BUDGET_BYTES),
		"Bridge records exact serialized snapshot packet count and byte ceiling")
	session.stop()
	for actor: Node in actors: actor.free()
	print("RESULT: ", failures.size(), " failures")
	quit(0 if failures.is_empty() else 1)
