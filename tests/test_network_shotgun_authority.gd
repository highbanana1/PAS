extends SceneTree
const Authority = preload("res://scene/script/network/match_authority.gd")
const Actor = preload("res://tests/fixtures/network_combat_actor.gd")
var failures: Array[String] = []
func _initialize() -> void: run.call_deferred()
func check(ok: bool, label: String) -> void:
	print(("PASS: " if ok else "FAIL: ") + label)
	if not ok: failures.append(label)
func actor_at(position: Vector2):
	var actor = Actor.new()
	actor.position = position
	root.add_child(actor)
	return actor
func shot_events(state: Dictionary) -> Array:
	return state.get("events", []).filter(func(e): return e.get("type") == "shot_spawned")
func run() -> void:
	var probe = Authority.new()
	check(probe.has_method("get_combat_state"), "Authority provides public combat state")
	if not probe.has_method("get_combat_state"):
		quit(1); return
	await test_fire_validation()
	await test_fire_cancels_guard()
	await test_hit(false)
	await test_hit(true)
	await test_wall(false)
	await test_wall(true)
	await test_wall_before_muzzle()
	await test_target_before_wall()
	await test_visible_radius()
	await test_player_overlap()
	await test_lifetime()
	print("RESULT: ", failures.size(), " failures")
	quit(0 if failures.is_empty() else 1)
func test_fire_validation() -> void:
	var a = Authority.new()
	var shooter = actor_at(Vector2.ZERO)
	a.register_player(&"shooter", shooter)
	await physics_frame
	check(not a.submit_command(&"unknown", {"type":"fire","direction":Vector2.RIGHT}, 1), "Unknown shooter is rejected")
	for direction in [Vector2.ZERO, Vector2(NAN, 0), Vector2(INF, 0), Vector2(1e30, 0), "right"]:
		check(not a.submit_command(&"shooter", {"type":"fire","direction":direction}, 1), "Invalid direction is rejected: " + str(direction))
	check(a.submit_command(&"shooter", {"type":"fire","direction":Vector2.RIGHT,"player_id":"victim","origin":Vector2(9999,9999),"damage":9999,"pellet_count":99,"speed":99999}, 2), "Valid aim accepted despite forged gameplay claims")
	a.step()
	var state: Dictionary = a.get_combat_state()
	var pellets: Array = state.projectiles
	check(pellets.size() == 5, "Exactly five independently tracked pellets spawn")
	var ids: Dictionary = {}
	for p in pellets:
		ids[p.pellet_id] = true
		check(p.player_id == "shooter", "Authority binds actual shooter identity")
		check(p.origin.distance_to(Vector2.ZERO) < 32.0, "Origin derives from host actor instead of client")
		check(p.velocity.length() < 800.0, "Client cannot forge projectile speed")
	check(ids.size() == 5, "Pellet identities are unique within shot")
	check(shot_events(state).size() == 1, "One fire produces one authoritative shot event")
	a.submit_command(&"shooter", {"type":"fire","direction":Vector2.RIGHT}, 3)
	a.step()
	check(shot_events(a.get_combat_state()).size() == 1, "Cooldown prevents a second shot next tick")
	for i in range(40): a.step()
	a.submit_command(&"shooter", {"type":"fire","direction":Vector2.RIGHT}, 4)
	a.step()
	check(shot_events(a.get_combat_state()).size() == 2, "Shot accepted after authoritative cooldown")
	shooter.force_dead()
	check(not a.submit_command(&"shooter", {"type":"fire","direction":Vector2.RIGHT}, 5), "Dead shooter cannot fire")
	shooter.free()
func test_fire_cancels_guard() -> void:
	var a = Authority.new()
	var shooter = actor_at(Vector2.ZERO)
	a.register_player(&"shooter", shooter)
	await physics_frame
	check(a.submit_command(&"shooter", {"type":"guard","enabled":true,"direction":Vector2.RIGHT}, 1), "Shooter raises guard before firing")
	var raised: Dictionary = a.get_guard_state(&"shooter")
	check(bool(raised.get("is_guarding", false)) and bool(raised.get("hold_requested", false)), "Guard is active with held intent")
	check(a.submit_command(&"shooter", {"type":"fire","direction":Vector2.RIGHT}, 2), "Valid fire is accepted while guarding")
	var after: Dictionary = a.get_guard_state(&"shooter")
	check(not bool(after.get("is_guarding", true)), "Fire immediately lowers the authoritative guard")
	check(not bool(after.get("hold_requested", true)), "Fire clears the held guard intent")
	a.step()
	after = a.get_guard_state(&"shooter")
	check(not bool(after.get("is_guarding", true)) and not bool(after.get("hold_requested", true)), "Held guard cannot silently resume after firing")
	shooter.free()
func test_hit(lethal: bool) -> void:
	var a = Authority.new()
	var shooter = actor_at(Vector2.ZERO)
	var target = actor_at(Vector2(48,0))
	target.health_component.set_current(5.0 if lethal else 31.0)
	target.damage_values.clear()
	a.register_player(&"shooter", shooter)
	a.register_player(&"target", target)
	await physics_frame
	a.submit_command(&"shooter", {"type":"fire","direction":Vector2.RIGHT}, 1)
	for i in range(8): a.step()
	if lethal:
		check(target.real_hp == 0 and target.is_dead, "Three pellets kill a five HP target")
		check(a.get_snapshot(&"target").dead, "Authority snapshot carries death")
	else:
		check(target.real_hp == 22.0, "Five hits process separately across cell boundary: 31 to 22")
		check(target.damage_values == [30.0,28.0,26.0,24.0,22.0], "Per pellet health sequence preserves overflow swallowing")
	check(a.get_combat_state().projectiles.is_empty(), "Hit pellets despawn on authority")
	check(shooter.real_hp == 150, "Pellets ignore their own shooter")
	shooter.free(); target.free()
func test_wall(overlap: bool) -> void:
	var a = Authority.new()
	var shooter = actor_at(Vector2.ZERO)
	var target = actor_at(Vector2(48,0))
	var wall := StaticBody2D.new()
	wall.collision_layer = 1
	wall.position = Vector2(16 if overlap else 32,0)
	var shape := CollisionShape2D.new()
	var rectangle := RectangleShape2D.new()
	rectangle.size = Vector2(1,80)
	shape.shape = rectangle
	wall.add_child(shape); root.add_child(wall)
	a.register_player(&"shooter", shooter); a.register_player(&"target", target)
	await physics_frame
	a.submit_command(&"shooter", {"type":"fire","direction":Vector2.RIGHT}, 1)
	for i in range(8): a.step()
	check(target.real_hp == 150, "Initial overlap blocks shot" if overlap else "Thin nearest wall blocks all fast pellets before player")
	check(a.get_combat_state().projectiles.is_empty(), "Wall collision removes pellets")
	shooter.free(); target.free(); wall.free()
func test_lifetime() -> void:
	var a = Authority.new()
	var shooter = actor_at(Vector2(-20000,-20000))
	a.register_player(&"shooter", shooter)
	await physics_frame
	a.submit_command(&"shooter", {"type":"fire","direction":Vector2.RIGHT}, 1)
	a.step()
	check(a.get_combat_state().projectiles.size() == 5, "Offscreen pellets exist on headless host")
	for i in range(20): a.step()
	check(a.get_combat_state().projectiles.size() == 5, "Offscreen visibility does not despawn authority projectiles")
	for i in range(180): a.step()
	check(a.get_combat_state().projectiles.is_empty(), "Bounded lifetime eventually removes missed pellets")
	shooter.free()

func test_target_before_wall() -> void:
	var a = Authority.new()
	var shooter = actor_at(Vector2.ZERO)
	var target = actor_at(Vector2(48,0))
	var wall := StaticBody2D.new()
	wall.position = Vector2(64,0); wall.collision_layer = 1
	var shape := CollisionShape2D.new()
	var rectangle := RectangleShape2D.new(); rectangle.size = Vector2(1,80)
	shape.shape = rectangle; wall.add_child(shape); root.add_child(wall)
	a.register_player(&"shooter", shooter); a.register_player(&"target", target)
	await physics_frame
	a.submit_command(&"shooter", {"type":"fire","direction":Vector2.RIGHT}, 1)
	for i in range(8): a.step()
	check(target.real_hp == 140, "Player nearer than wall receives all five pellets")
	check(a.get_combat_state().projectiles.is_empty(), "Nearest player stops pellets before farther wall")
	shooter.free(); target.free(); wall.free()

func test_wall_before_muzzle() -> void:
	var a = Authority.new()
	var shooter = actor_at(Vector2.ZERO)
	var target = actor_at(Vector2(48,0))
	var wall := StaticBody2D.new()
	wall.collision_layer = 1
	wall.position = Vector2(12,0)
	var shape := CollisionShape2D.new()
	var rectangle := RectangleShape2D.new()
	rectangle.size = Vector2(1,80)
	shape.shape = rectangle
	wall.add_child(shape); root.add_child(wall)
	a.register_player(&"shooter", shooter); a.register_player(&"target", target)
	await physics_frame
	a.submit_command(&"shooter", {"type":"fire","direction":Vector2.RIGHT}, 1)
	a.step()
	check(target.real_hp == 150, "Wall between actor and muzzle prevents behind-wall spawn damage")
	check(a.get_combat_state().projectiles.is_empty(), "Muzzle clearance collision removes all five pellets")
	shooter.free(); target.free(); wall.free()

func test_visible_radius() -> void:
	var a = Authority.new()
	var shooter = actor_at(Vector2.ZERO)
	var target = actor_at(Vector2(48,32))
	a.register_player(&"shooter", shooter); a.register_player(&"target", target)
	await physics_frame
	a.submit_command(&"shooter", {"type":"fire","direction":Vector2.RIGHT}, 1)
	for i in range(8): a.step()
	check(target.real_hp == 150, "Visible pellet radius does not hit a nearby off-trajectory player")
	shooter.free(); target.free()
func test_player_overlap() -> void:
	var a = Authority.new()
	var shooter = actor_at(Vector2.ZERO)
	var target = actor_at(Vector2(16,0))
	a.register_player(&"shooter", shooter); a.register_player(&"target", target)
	await physics_frame
	a.submit_command(&"shooter", {"type":"fire","direction":Vector2.RIGHT}, 1)
	a.step()
	check(target.real_hp == 140, "Projectile initial overlap hits target without tunneling")
	check(shooter.real_hp == 150, "Shooter excluded even when target overlaps muzzle")
	shooter.free(); target.free()
