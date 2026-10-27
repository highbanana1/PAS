extends SceneTree

const Session = preload("res://scene/script/network/network_session.gd")
const Bridge = preload("res://scene/script/network/match_network_bridge.gd")
const Actor = preload("res://tests/fixtures/network_combat_actor.gd")
const Star = preload("res://scene/script/winning_point.gd")

var failures: Array[String] = []

func _initialize() -> void:
	run.call_deferred()

func check(value: bool, label: String) -> void:
	print(("PASS: " if value else "FAIL: ") + label)
	if not value: failures.append(label)

func run() -> void:
	var map := Node2D.new()
	root.add_child(map)
	var star = Star.new()
	star.name = "FreeStar"
	map.add_child(star)
	star.global_position = Vector2(100, -100)
	var session = Session.new()
	root.add_child(session)
	var bridge = Bridge.new()
	root.add_child(bridge)
	check(session.host(0, {"match_epoch": 606608}) == OK and bridge.configure(session),
		"Host and bridge start")
	bridge.bind_world(map)
	var actor = Actor.new()
	actor.position = star.global_position
	root.add_child(actor)
	check(bridge.bind_actor(&"player_2", actor), "Host keeps a remote actor beside a free star")
	session.player_left.emit(2, "player_2")
	check(not bool(bridge.get_authority().get_snapshot(&"player_2").get("online", true)),
		"Transport loss suspends the actor")
	for _tick in range(10): await physics_frame
	var state: Dictionary = bridge.get_extraction_state().get("stars", {}).get("FreeStar", {})
	check(String(state.get("state", "")) == "FREE",
		"An offline actor cannot automatically pick up a new star")
	session.stop()
	print("RESULT: ", failures.size(), " failures")
	quit(0 if failures.is_empty() else 1)
