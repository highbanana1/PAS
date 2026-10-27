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
	root.add_child(map)
	var stars: Array = []
	for index in range(4):
		var star = Star.new()
		star.name = "Star%d" % index
		map.add_child(star)
		star.global_position = Vector2(100 + index * 80, -100)
		stars.append(star)
	var table = Table.new()
	table.name = "Exit"
	table.add_to_group("table")
	map.add_child(table)
	table.global_position = Vector2.ZERO
	var session = Session.new()
	root.add_child(session)
	var bridge = Bridge.new()
	bridge.auto_bind_world = false
	root.add_child(bridge)
	check(session.host(0, {"match_epoch": 707707}) == OK and bridge.configure(session),
		"Host starts with deferred map registration")
	check(not bridge.can_submit_command(), "Lobby rejects gameplay input before the match starts")
	var actors: Array = []
	for index in range(5):
		var actor = Actor.new()
		actor.position = Vector2(-300 + index * 20, 0)
		root.add_child(actor)
		actors.append(actor)
		bridge.bind_actor(StringName("player_%d" % index), actor)
	bridge.bind_world(map, 2)
	var extraction: Dictionary = bridge.get_extraction_state()
	check(extraction.get("stars", {}).size() == 2 and extraction.get("points", {}).size() == 1,
		"Five opening players activate two map stars and the authored exit")
	check(stars[0].visible and stars[1].visible and not stars[2].visible and not stars[3].visible,
		"Unused star candidates are hidden instead of becoming fake pickups")
	check(bridge.start_match() and int(bridge.get_match_state().get("star_quota", 0)) == 2,
		"The host freezes the opening quota from its registered roster")
	check(bridge.can_submit_command(), "Gameplay input is enabled after the host starts the match")
	bridge._send_snapshot()
	check(not bridge.get_last_snapshot_batch().has("combat"),
		"Unreliable movement snapshots leave combat state to the reliable stream")
	var batch: Dictionary = bridge.get_last_snapshot_batch()
	var compact_players: Dictionary = batch.get("players", {})
	check(not compact_players["player_0"].has("guard")
		and not compact_players["player_0"].has("items")
		and compact_players["player_0"].has("ack_sequence"),
		"Movement snapshots carry prediction fields without duplicated inventory")
	var first_three: Dictionary = {}
	for index in range(3):
		first_three["player_%d" % index] = compact_players["player_%d" % index]
	var three_player_packet := {"match_epoch": session.get_match_epoch(),
		"server_tick": bridge.get_authority().get_tick(), "players": first_three}
	check(var_to_bytes(three_player_packet).size() < 1392,
		"Three-player motion payload fits below the observed ENet MTU")
	session.stop()
	check(stars[2].visible and stars[3].visible,
		"Closing the session restores offline visibility")
	for actor in actors: actor.free()
	print("RESULT: ", failures.size(), " failures")
	quit(0 if failures.is_empty() else 1)
