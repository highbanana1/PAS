extends SceneTree

const Authority = preload("res://scene/script/network/match_authority.gd")
const Actor = preload("res://tests/fixtures/network_combat_actor.gd")
const CombatReplica = preload("res://scene/script/network/combat_replica.gd")

var failures: Array[String] = []

func _initialize() -> void:
	run.call_deferred()

func check(ok: bool, label: String) -> void:
	print(("PASS: " if ok else "FAIL: ") + label)
	if not ok: failures.append(label)

func actor_at(position: Vector2):
	var actor = Actor.new()
	actor.position = position
	root.add_child(actor)
	return actor

func run() -> void:
	await test_deadline_tie_and_late_join()
	await test_time_limit_and_no_contenders()
	await test_map_supply_matches_opening_roster()
	print("RESULT: ", failures.size(), " failures")
	quit(0 if failures.is_empty() else 1)

func test_deadline_tie_and_late_join() -> void:
	var authority = Authority.new()
	authority.configure_extraction(0.05)
	var owner = actor_at(Vector2.ZERO)
	var newcomer = actor_at(Vector2(200, 0))
	check(authority.register_player(&"owner", owner), "Opening player is registered")
	authority.register_star(&"star", Vector2.ZERO)
	authority.register_extraction_point(&"point", Vector2.ZERO)
	check(authority.start_match(3), "One opening player starts with one star")
	check(authority.register_player(&"newcomer", newcomer), "A late join enters the running match")
	check(int(authority.get_match_state().get("star_quota", 0)) == 1
		and int(authority.get_match_state().get("opening_player_count", 0)) == 1,
		"Late joining does not add an extraction slot")
	await physics_frame
	check(authority.submit_command(&"owner", {"type": "star_pickup", "star_id": "star",
		"expected_revision": 1}), "Opening player picks up a star")
	check(authority.submit_command(&"owner", {"type": "deliver_star", "point_id": "point",
		"expected_revision": 2}), "Opening player starts extraction")
	for _tick in range(3): authority.step()
	var match_state: Dictionary = authority.get_match_state()
	check(bool(match_state.get("ended", false)) and int(match_state.get("end_tick", -1)) == 3,
		"Extraction and match deadline settle on the same authority tick")
	check(String(match_state.get("results", {}).get("owner", "")) == "win"
		and String(match_state.get("results", {}).get("newcomer", "")) == "loss",
		"Same-tick evacuee wins; remaining contender loses")
	check(authority.get_combat_state().get("match", {}).get("results", {}) == match_state.get("results", {}),
		"The match result is included in the replicated combat checkpoint")
	var replica = CombatReplica.new()
	replica.configure(707708)
	check(replica.apply_packet({"match_epoch": 707708, "server_tick": authority.get_tick(),
		"players": authority.get_snapshots(), "combat": authority.get_combat_state()})
		and replica.get_match().get("results", {}) == match_state.get("results", {}),
		"A client checkpoint reconstructs the final result")
	check(not authority.submit_command(&"newcomer", {"type": "move", "direction": Vector2.RIGHT}),
		"An ended match rejects further gameplay commands")
	owner.free()
	newcomer.free()

func test_time_limit_and_no_contenders() -> void:
	var timed = Authority.new()
	var player = actor_at(Vector2.ZERO)
	timed.register_player(&"timed", player)
	timed.register_star(&"s", Vector2(300, 0))
	timed.register_extraction_point(&"p", Vector2.ZERO)
	check(timed.start_match(2), "A test match accepts a two-tick clock")
	timed.step()
	check(not bool(timed.get_match_state().get("ended", false)), "Time remains before the deadline")
	timed.step()
	check(String(timed.get_match_state().get("end_reason", "")) == "time_limit"
		and String(timed.get_match_state().get("results", {}).get("timed", "")) == "loss",
		"Time limit ends the match and fails unextracted players")
	player.free()
	var empty = Authority.new()
	var leaving = actor_at(Vector2.ZERO)
	empty.register_player(&"leaving", leaving)
	empty.register_star(&"s", Vector2.ZERO)
	empty.register_extraction_point(&"p", Vector2.ZERO)
	empty.start_match()
	check(empty.suspend_player(&"leaving") and empty.expire_player(&"leaving"),
		"The final reserved contender times out")
	empty.step()
	check(String(empty.get_match_state().get("end_reason", "")) == "no_contenders"
		and String(empty.get_match_state().get("results", {}).get("leaving", "")) == "loss",
		"Removing the final contender ends the match")
	leaving.free()

func test_map_supply_matches_opening_roster() -> void:
	var authority = Authority.new()
	var actors: Array = []
	for index in range(5):
		var actor = actor_at(Vector2(index * 20, 0))
		actors.append(actor)
		authority.register_player(StringName("player_%d" % index), actor)
	authority.register_extraction_point(&"point", Vector2.ZERO)
	authority.register_star(&"one", Vector2.ZERO)
	check(not authority.start_match(), "Five opening players cannot start with one star")
	authority.register_star(&"two", Vector2(100, 0))
	check(authority.start_match(), "Five opening players start with exactly two stars")
	check(int(authority.get_match_state().get("star_quota", 0)) == 2,
		"The opening star quota is frozen at two")
	for actor in actors: actor.free()
