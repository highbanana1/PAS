extends SceneTree

const Session = preload("res://scene/script/network/network_session.gd")
const Bridge = preload("res://scene/script/network/match_network_bridge.gd")
const Actor = preload("res://tests/fixtures/network_combat_actor.gd")
const Star = preload("res://scene/script/winning_point.gd")
const Table = preload("res://scene/script/wtable.gd")
var failures: Array[String] = []

func _initialize() -> void:
	run.call_deferred()

func check(ok: bool, label: String) -> void:
	print(("PASS: " if ok else "FAIL: ") + label)
	if not ok: failures.append(label)

func run() -> void:
	var map := Node2D.new()
	map.name = "Map"
	root.add_child(map)
	var star = Star.new()
	star.name = "Star"
	map.add_child(star)
	star.global_position = Vector2(100, -100)
	var far_star = Star.new()
	far_star.name = "FarStar"
	map.add_child(far_star)
	far_star.global_position = Vector2(200, -100)
	var point = Table.new()
	point.name = "Point"
	point.add_to_group("table")
	map.add_child(point)
	point.global_position = Vector2(100, -100)
	var actor = Actor.new()
	actor.position = Vector2(100, -100)
	root.add_child(actor)
	var session = Session.new()
	session.name = "NetworkSession"
	root.add_child(session)
	var bridge = Bridge.new()
	bridge.name = "MatchNetworkBridge"
	root.add_child(bridge)
	check(session.host(0, {"match_epoch": 505506}) == OK and bridge.configure(session),
		"Host session starts for actual scene nodes")
	check(bridge.configure_extraction(0.1), "Host can configure a six-tick map countdown")
	bridge.bind_world(map)
	var player_id: StringName = StringName(String(session.get_local_identity().player_id))
	check(bridge.bind_actor(player_id, actor, true), "Real map player is bound to host authority")
	for _tick in range(20): await physics_frame
	var state: Dictionary = bridge.get_extraction_state()
	var stars: Dictionary = state.get("stars", {})
	var points: Dictionary = state.get("points", {})
	check(stars.size() == 2 and points.size() == 1, "Bridge registers both map stars and one point")
	check(String(stars.get("FarStar", {}).get("state", "")) == "FREE"
		and stars.get("FarStar", {}).get("position", Vector2.ZERO) == Vector2(200, -100),
		"A second placed star keeps its map position and remains available")
	var winner: Dictionary = bridge.get_authority().get_snapshot(player_id)
	check(bool(winner.get("extracted", false)) and bool(winner.get("spectating", false)),
		"Existing scene star is picked and delivered through the host")
	check(not star.visible and star.network_controlled and point.network_controlled,
		"Consumed star is hidden while map nodes use network authority")
	session.stop()
	check(not star.network_controlled and not point.network_controlled,
		"Closing session restores the existing offline scene path")
	print("RESULT: ", failures.size(), " failures")
	quit(0 if failures.is_empty() else 1)
