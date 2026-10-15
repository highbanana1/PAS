extends SceneTree
var failures: Array[String] = []
func _initialize() -> void: run.call_deferred()
func check(ok: bool, text: String) -> void:
	print(("PASS: " if ok else "FAIL: ") + text)
	if not ok: failures.append(text)
func visible_cells(cells: Array) -> int:
	var count := 0
	for cell in cells:
		if cell.visible: count += 1
	return count
func run() -> void:
	var game = load("res://scene/main.tscn").instantiate()
	root.add_child(game); current_scene = game
	var player = game.get_node("CharacterBody2D")
	player.set_physics_process(false); player.get_weapon_controller().set_process(false)
	var enemy = game.get_node("enemy"); enemy.set_physics_process(false)
	var hud = game.get_node("UILayer")
	check(hud.has_method("get_health_cells") and player.has_method("queue_contact_damage"), "Health HUD exposes independent cells and queued contact damage")
	if not hud.has_method("get_health_cells") or not player.has_method("queue_contact_damage"):
		game.free(); quit(1); return
	var cells: Array = hud.get_health_cells()
	check(cells.size() == 8 and visible_cells(cells) == 5 and player.real_hp == 150 and player.max_hp == 150, "Game starts with five thirty-health cells from an eight-cell pool")
	player.take_damage(15)
	check(player.real_hp == 135 and visible_cells(cells) == 5 and cells[4].value == 15, "Partial damage stays visible in the current cell")
	player.take_damage(100)
	check(player.real_hp == 120 and visible_cells(cells) == 4 and not cells[4].visible, "An emptied cell disappears and excess damage cannot reach the next one")
	player.real_hp = 125
	player.take_damage(15)
	check(player.real_hp == 120 and cells[3].value == 30 and not cells[4].visible, "Five remaining health absorbs fifteen damage without touching the next cell")
	player.take_damage(10000)
	check(player.real_hp == 90 and not player.is_dead and visible_cells(cells) == 3, "Even a huge hit removes at most the current full cell")
	player.get_health_component().restore_full()
	check(player.real_hp == 150 and visible_cells(cells) == 5, "Healing restores depleted cells within the current maximum")
	player.max_hp = 1000
	player.get_health_component().restore_full()
	check(player.max_hp == 240 and player.real_hp == 240 and visible_cells(cells) == 8, "Maximum health cannot exceed eight cells")
	check(enemy.contact_damage == 15, "Small enemy contact damage is fifteen")
	enemy._on_area_2d_body_entered(player); player.hit_cooldown(0.0)
	check(player.real_hp == 225 and not player.hitable, "Actual enemy contact consumes fifteen health and starts existing protection")
	enemy._on_area_2d_body_entered(player); player.hit_cooldown(0.0)
	check(player.real_hp == 225, "Invincibility prevents repeated contact damage")
	player._on_timer_timeout()
	enemy._on_area_2d_body_entered(player); player.hit_cooldown(0.0)
	check(player.real_hp == 210 and visible_cells(cells) == 7, "Two enemy hits empty a full thirty-health cell")
	enemy.get_health_component().configure(100)
	enemy.hurt(45)
	check(enemy.health == 55, "Enemy health remains unsegmented and takes its full incoming damage")
	player.real_hp = 10
	player.take_damage(1000)
	check(player.is_dead and player.real_hp == 0 and visible_cells(cells) == 0, "Losing the final cell hides every cell and still causes death")
	player.respawn(player.spawn_position)
	check(player.real_hp == 150 and player.max_hp == 240 and visible_cells(cells) == 5, "Respawn restores five cells while retaining maximum upgrade capacity")
	game.free()
	print("RESULT: ", failures.size(), " failures")
	quit(0 if failures.is_empty() else 1)
