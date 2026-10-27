extends SceneTree

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

func star(authority, id: String = "s1") -> Dictionary:
	return authority.get_extraction_state().get("stars", {}).get(id, {})

func command(type: String, id: String, revision: int) -> Dictionary:
	var result := {"type": type, "expected_revision": revision}
	result["star_id" if type == "star_pickup" else "point_id"] = id
	return result

func run() -> void:
	check(int(Authority.new().get_extraction_state().duration_ticks) == 1800,
		"Default extraction countdown is exactly thirty seconds")
	await test_pickup_delivery_death_and_revival()
	await test_damage_does_not_cancel()
	await test_deadline_wins_same_tick_melee()
	print("RESULT: ", failures.size(), " failures")
	quit(0 if failures.is_empty() else 1)

func test_pickup_delivery_death_and_revival() -> void:
	var a = Authority.new()
	check(a.configure_extraction(0.1), "Host configures a six-tick extraction window")
	check(a.register_star(&"s1", Vector2.ZERO), "Host registers a free star")
	check(a.register_star(&"s2", Vector2.ZERO), "Host registers another free star")
	check(a.register_extraction_point(&"p1", Vector2.ZERO, 48.0), "Map registers an extraction point")
	var p1 = actor_at(Vector2.ZERO)
	var p2 = actor_at(Vector2.ZERO)
	p1.respawn_delay = 0.05
	a.register_player(&"p1", p1)
	a.register_player(&"p2", p2)
	await physics_frame
	check(a.submit_command(&"p1", command("star_pickup", "s1", 1)), "Player picks first star")
	check(not a.submit_command(&"p1", command("star_pickup", "s2", 1)), "Player cannot carry two stars")
	check(not a.submit_command(&"p2", command("star_pickup", "s1", 1)), "Stale pickup cannot steal a carried star")
	check(a.submit_command(&"p1", command("deliver_star", "p1", 2)), "Carrier binds star to free point")
	check(a.submit_command(&"p2", command("star_pickup", "s2", 1)), "Second player picks second star")
	check(not a.submit_command(&"p2", command("deliver_star", "p1", 2)), "Point admits one carrier at a time")
	check(not a.submit_command(&"p2", command("star_pickup", "s1", 3)), "Bound star cannot be stolen")
	p1.global_position = Vector2(100, 0)
	a.step()
	check(String(star(a).state) == "CARRIED" and String(star(a).owner) == "p1",
		"Leaving point returns star to its deliverer")
	check(String(a.get_extraction_state().points.p1.occupant) == "", "Cancellation frees point")
	p1.global_position = Vector2.ZERO
	check(a.submit_command(&"p1", command("deliver_star", "p1", 4)), "Deliverer can restart a fresh countdown")
	p1.global_position = Vector2(17, 4)
	p1.force_dead()
	a.step()
	check(String(star(a).state) == "FREE" and star(a).position == Vector2(17, 4),
		"Death drops bound star once at death position")
	var dropped_revision := int(star(a).revision)
	a.step()
	check(int(star(a).revision) == dropped_revision, "Repeated dead ticks do not duplicate a drop")
	for _tick in range(5): a.step()
	check(not p1.is_dead, "Player revives through existing authority lifecycle")
	p1.global_position = Vector2(17, 4)
	check(a.submit_command(&"p1", command("star_pickup", "s1", dropped_revision)), "Revived player can reclaim the dropped star")
	var detached := a.get_extraction_state()
	detached.stars.s1.owner = "forged"
	check(String(star(a).owner) == "p1", "Caller cannot mutate the authoritative star snapshot")
	p1.free(); p2.free()

func test_damage_does_not_cancel() -> void:
	var a = Authority.new()
	a.configure_extraction(0.05)
	a.register_star(&"s1", Vector2.ZERO)
	a.register_extraction_point(&"p1", Vector2.ZERO)
	var actor = actor_at(Vector2.ZERO)
	a.register_player(&"player", actor)
	await physics_frame
	a.submit_command(&"player", command("star_pickup", "s1", 1))
	a.submit_command(&"player", command("deliver_star", "p1", 2))
	actor.health_component.set_current(135.0)
	a.step(); a.step(); a.step()
	check(String(star(a).state) == "CONSUMED" and bool(a.get_snapshot(&"player").extracted),
		"Nonlethal damage does not interrupt extraction")
	actor.free()

func test_deadline_wins_same_tick_melee() -> void:
	var a = Authority.new()
	a.configure_extraction(0.05)
	a.register_star(&"s1", Vector2(24, 0))
	a.register_extraction_point(&"p1", Vector2(24, 0), 48.0)
	var attacker = actor_at(Vector2.ZERO)
	var winner = actor_at(Vector2(24, 0))
	winner.health_component.set_current(2.0)
	a.register_player(&"attacker", attacker)
	a.register_player(&"winner", winner)
	await physics_frame
	a.submit_command(&"winner", command("star_pickup", "s1", 1))
	a.submit_command(&"winner", command("deliver_star", "p1", 2))
	a.submit_command(&"winner", {"type": "fire", "direction": Vector2.RIGHT})
	a.submit_command(&"attacker", {"type": "sword", "direction": Vector2.RIGHT, "action_id": 1})
	a.step(); a.step(); a.step()
	var state: Dictionary = a.get_snapshot(&"winner")
	check(bool(state.extracted) and bool(state.spectating), "Deadline makes the carrier a spectator before same-tick hit")
	check(String(star(a).state) == "CONSUMED" and is_equal_approx(float(winner.real_hp), 2.0),
		"Same-tick lethal sword cannot undo completed extraction")
	var projectiles: Array = a.get_combat_state().get("projectiles", [])
	check(projectiles.is_empty(), "A queued shot from the winner cannot fire after extraction")
	check(not a.submit_command(&"winner", {"type": "move", "direction": Vector2.RIGHT}),
		"Winner cannot return to combat")
	check(a.submit_command(&"attacker", {"type": "move", "direction": Vector2.RIGHT}),
		"Other participants continue playing")
	attacker.free(); winner.free()
