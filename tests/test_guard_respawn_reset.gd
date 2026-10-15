extends SceneTree
var failures: Array[String] = []
func _initialize() -> void: run.call_deferred()
func check(ok: bool, label: String) -> void:
	print(("PASS: " if ok else "FAIL: ") + label)
	if not ok: failures.append(label)
func run() -> void:
	var game = load("res://scene/main.tscn").instantiate()
	root.add_child(game); current_scene = game
	var p = game.get_node("CharacterBody2D")
	p.set_physics_process(false); game.get_node("enemy").set_physics_process(false)
	var w = p.get_weapon_controller(); w.set_process(false); w.equip_weapon(1)
	var g = p.get_guard_component()
	g.request_guard(true); g.tick(10.0)
	g.request_guard(true); g.tick(7.5); g.request_guard(true)
	check(g.value == 50 and not g.is_guarding, "Holding right click during exhausted recovery restores half without guarding or draining")
	g.request_guard(true); g.tick(7.4); g.request_guard(true)
	check(g.value < 100 and not g.is_guarding, "Guard stays locked immediately before full recovery")
	g.request_guard(false); g.tick(0.1); g.request_guard(true)
	check(g.value == 100 and g.is_guarding, "Full recovery unlocks guarding")
	g.value = 20
	check(p.receive_attack(1, p.global_position + Vector2.RIGHT * 40) and g.value == 0, "An attack can exhaust the remaining guard")
	g.request_guard(false); g.tick(3); g.request_guard(true)
	check(not g.is_guarding, "Attack exhaustion also locks partially recovered guard")
	p.max_hp = 240; p.real_hp = 10; p.take_damage(100)
	p.can_dash = false; p.is_dashing = true; p.jump_count = 0; p.dash_timer = 2
	p.velocity = Vector2(50, 50); p.hitcooltimer = 2; p.damage_timer = 2
	p.get_hit = true; p.get_node("Timer").start(2)
	p.respawn(p.spawn_position)
	var cells: Array = game.get_node("UILayer").get_health_cells()
	var visible_count := 0
	for cell in cells:
		if cell.visible: visible_count += 1
	check(p.real_hp == 150 and visible_count == 5, "Respawn returns with five full health cells even after capacity increases")
	check(g.value == 100 and not g.is_guarding and not g.hold_requested, "Respawn restores full guard and clears guarding input")
	g.request_guard(true)
	check(g.is_guarding, "Respawn clears exhaustion lock immediately")
	check(p.can_dash and not p.is_dashing and p.jump_count == 1 and p.dash_timer == 0 and p.velocity == Vector2.ZERO, "Respawn resets movement and jump/dash availability")
	check(p.hitable and not p.get_hit and p.hitcooltimer == 0 and p.damage_timer == 0 and p.get_node("Timer").is_stopped(), "Respawn clears contact damage and invincibility timers")
	check(not p.get_node("Sword").is_swinging and p.get_node("Sword")._cooldown_left == 0 and not p.get_hurt_presentation().is_playing, "Respawn clears swing cooldown and hurt animation")
	game.free()
	print("RESULT: ", failures.size(), " failures")
	quit(0 if failures.is_empty() else 1)
