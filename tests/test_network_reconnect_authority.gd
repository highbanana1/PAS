extends SceneTree

## Ticket 06 contract for a retained, offline player. MatchAuthority owns
## gameplay state; NetworkSession/Bridge own the 30-second reservation clock.
const Authority = preload("res://scene/script/network/match_authority.gd")
const Actor = preload("res://tests/fixtures/network_combat_actor.gd")

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
	await test_suspend_clears_input_but_keeps_lifecycle()
	await test_offline_extraction_and_resume()
	await test_expiry_drops_owned_state_once()
	await test_death_then_expiry_does_not_drop_twice()
	print("RESULT: ", failures.size(), " failures")
	quit(0 if failures.is_empty() else 1)

func test_suspend_clears_input_but_keeps_lifecycle() -> void:
	var authority = Authority.new()
	var actor = actor_at(Vector2(20, 10))
	actor.respawn_delay = 0.05
	check(authority.register_player(&"offline", actor), "A player joins the authority")
	await physics_frame
	check(authority.submit_command(&"offline", {"type": "move", "direction": Vector2.RIGHT}),
		"Movement is accepted before disconnection")
	check(authority.submit_command(&"offline", {"type": "guard", "enabled": true,
		"direction": Vector2.RIGHT}), "Guard starts before disconnection")
	check(authority.suspend_player(&"offline"), "Disconnect retains the player")
	check(not authority.get_guard_state(&"offline").get("is_guarding", true),
		"Disconnect cancels guard and its ongoing meter drain")
	check(not authority.submit_command(&"offline", {"type": "move", "direction": Vector2.RIGHT}),
		"Disconnected player cannot submit gameplay commands")
	var still_position: Vector2 = actor.global_position
	for _tick in range(4): authority.step()
	check(actor.global_position.distance_to(still_position) < 0.01,
		"A queued movement command does not move the offline actor")
	check(authority.get_player_ids().has(&"offline"),
		"Offline actor stays registered and attackable")
	actor.force_dead()
	for _tick in range(5): authority.step()
	var revived: Dictionary = authority.get_snapshot(&"offline")
	check(not actor.is_dead and int(revived.get("life_id", 0)) == 2,
		"Death and timed respawn continue while offline")
	check(authority.resume_player(&"offline"), "Reconnection resumes the retained player")
	check(authority.submit_command(&"offline", {"type": "move", "direction": Vector2.RIGHT}),
		"Reconnected player can submit commands on the current life")
	actor.free()

func test_offline_extraction_and_resume() -> void:
	var authority = Authority.new()
	authority.configure_extraction(0.05)
	authority.register_star(&"star", Vector2.ZERO)
	authority.register_extraction_point(&"point", Vector2.ZERO)
	var actor = actor_at(Vector2.ZERO)
	check(authority.register_player(&"evacuee", actor), "Evacuee joins")
	await physics_frame
	check(authority.submit_command(&"evacuee", {"type": "star_pickup", "star_id": "star",
		"expected_revision": 1}), "Evacuee picks up the star")
	check(authority.submit_command(&"evacuee", {"type": "deliver_star", "point_id": "point",
		"expected_revision": 2}), "Evacuee starts the countdown")
	check(authority.suspend_player(&"evacuee"), "Evacuee disconnects without cancelling extraction")
	for _tick in range(3): authority.step()
	var won: Dictionary = authority.get_snapshot(&"evacuee")
	check(bool(won.get("extracted", false)), "Offline player can finish the countdown")
	check(String(authority.get_extraction_state().get("stars", {}).get("star", {}).get("state", ""))
		== "CONSUMED", "Offline victory consumes one star")
	check(authority.resume_player(&"evacuee"), "Winner can reconnect to spectator state")
	check(not authority.submit_command(&"evacuee", {"type": "move", "direction": Vector2.RIGHT}),
		"Reconnected winner cannot re-enter combat")
	actor.free()

func test_expiry_drops_owned_state_once() -> void:
	var authority = Authority.new()
	authority.register_star(&"star", Vector2(30, 40))
	authority.register_extraction_point(&"point", Vector2(30, 40))
	var actor = actor_at(Vector2(30, 40))
	check(authority.register_player(&"expired", actor), "Expiring player joins")
	await physics_frame
	var item_id: int = authority.grant_item(&"expired", &"health", 30.0, 30.0)
	check(item_id > 0, "Host gives the player a carried item")
	check(authority.submit_command(&"expired", {"type": "star_pickup", "star_id": "star",
		"expected_revision": 1}), "Player carries a star")
	check(authority.submit_command(&"expired", {"type": "deliver_star", "point_id": "point",
		"expected_revision": 2}), "Player occupies an extraction point")
	check(authority.suspend_player(&"expired"), "Player disconnects")
	check(authority.expire_player(&"expired"), "Reservation expiry removes the player")
	var extraction: Dictionary = authority.get_extraction_state()
	var dropped_star: Dictionary = extraction.get("stars", {}).get("star", {})
	var dropped_item: Dictionary = authority.get_item(item_id)
	check(String(dropped_star.get("state", "")) == "FREE"
		and dropped_star.get("position", Vector2.ZERO) == Vector2(30, 40),
		"Expiry drops the bound star at the last actor position")
	check(String(extraction.get("points", {}).get("point", {}).get("occupant", "missing")) == "",
		"Expiry frees the occupied extraction point")
	check(String(dropped_item.get("state", "")) == "world"
		and dropped_item.get("position", {}) == {"x": 30.0, "y": 40.0},
		"Expiry drops the carried item at the same position")
	check(not authority.get_player_ids().has(&"expired"), "Expiry unregisters the player")
	var star_revision: int = int(dropped_star.get("revision", -1))
	var item_revision: int = int(dropped_item.get("revision", -1))
	check(not authority.expire_player(&"expired"), "Repeated expiry is idempotently rejected")
	check(int(authority.get_extraction_state().get("stars", {}).get("star", {}).get("revision", -2))
		== star_revision and int(authority.get_item(item_id).get("revision", -2)) == item_revision,
		"Repeated expiry does not duplicate or move drops")
	actor.free()

func test_death_then_expiry_does_not_drop_twice() -> void:
	var authority = Authority.new()
	authority.register_star(&"star", Vector2.ZERO)
	var actor = actor_at(Vector2.ZERO)
	actor.respawn_delay = 999.0
	check(authority.register_player(&"fallen", actor), "Fallen player joins")
	await physics_frame
	var item_id: int = authority.grant_item(&"fallen", &"health", 30.0, 30.0)
	check(authority.submit_command(&"fallen", {"type": "star_pickup", "star_id": "star",
		"expected_revision": 1}), "Fallen player carries a star")
	check(authority.suspend_player(&"fallen"), "Fallen player disconnects")
	actor.force_dead()
	authority.step()
	var death_star: Dictionary = authority.get_extraction_state().get("stars", {}).get("star", {})
	var death_item: Dictionary = authority.get_item(item_id)
	check(String(death_star.get("state", "")) == "FREE"
		and String(death_item.get("state", "")) == "world",
		"Death drops the offline player's inventory and star")
	check(authority.expire_player(&"fallen"), "The reservation expires after death")
	check(int(authority.get_extraction_state().get("stars", {}).get("star", {}).get("revision", -1))
		== int(death_star.get("revision", -2))
		and int(authority.get_item(item_id).get("revision", -1))
		== int(death_item.get("revision", -2)),
		"Expiry does not duplicate drops already made by death")
	actor.free()
