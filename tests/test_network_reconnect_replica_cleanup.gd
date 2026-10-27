extends SceneTree

const Bridge = preload("res://scene/script/network/match_network_bridge.gd")
const Replica = preload("res://scene/script/network/snapshot_replica.gd")

var failures: Array[String] = []

func _initialize() -> void:
	run.call_deferred()

func check(value: bool, label: String) -> void:
	print(("PASS: " if value else "FAIL: ") + label)
	if not value: failures.append(label)

func run() -> void:
	var bridge = Bridge.new()
	root.add_child(bridge)
	bridge.replica = Replica.new()
	bridge.replica.configure(606607)
	var actor := Node2D.new()
	root.add_child(actor)
	bridge._actors["player_2"] = actor
	var baseline := {"match_epoch": 606607, "baseline_tick": 1,
		"players": {"player_2": {"player_id": "player_2", "revision": 1,
			"position": Vector2(12, 34), "velocity": Vector2.ZERO}}}
	check(bool(bridge.replica.apply_baseline(baseline).get("applied", false)),
		"Client accepts a full roster baseline")
	bridge._apply_all_replicas()
	check(is_instance_valid(actor) and bridge.get_bound_actor(&"player_2") == actor,
		"A present remote actor remains visible")
	var next := {"match_epoch": 606607, "server_tick": 2, "players": {}}
	check(bool(bridge.replica.apply_batch(next).get("applied", false)),
		"Client accepts a roster without the departed player")
	bridge._apply_all_replicas()
	await process_frame
	check(not is_instance_valid(actor) and bridge.get_bound_actor(&"player_2") == null,
		"An expired remote actor is removed from the client scene")
	print("RESULT: ", failures.size(), " failures")
	quit(0 if failures.is_empty() else 1)
