extends SceneTree

var failures: Array[String] = []

func _initialize() -> void:
	_run.call_deferred()

func check(condition: bool, message: String) -> void:
	if condition:
		print("PASS: " + message)
	else:
		failures.append(message)
		push_error("FAIL: " + message)

func enemy_at(game: Node, point: Vector2) -> Node2D:
	var enemy = load("res://scene/enemy.tscn").instantiate()
	enemy.scale = Vector2(0.045, 0.045)
	enemy.position = point
	game.add_child(enemy)
	enemy.set_physics_process(false)
	return enemy

func _run() -> void:
	var game: Node2D = load("res://scene/main.tscn").instantiate()
	root.add_child(game)
	current_scene = game
	var player = game.get_node("CharacterBody2D")
	player.set_physics_process(false)
	player.global_position = Vector2(1500, -300)
	game.get_node("enemy").set_physics_process(false)
	var weapons = player.get_node_or_null("WeaponController")
	var hud = game.get_node_or_null("CombatHUD")
	check(weapons != null and hud != null, "Player has sword/guard control and matching combat HUD")
	if weapons == null or hud == null:
		game.free()
		print("RESULT: ", failures.size(), " failures")
		quit(1)
		return
	weapons.set_process(false)
	var sword = player.get_node("Sword")
	check(weapons.current_weapon == 0 and player.get_node("gun").is_processing() and not sword.visible, "Gun remains the initial weapon")
	var scroll := InputEventMouseButton.new()
	scroll.button_index = MOUSE_BUTTON_WHEEL_DOWN
	scroll.pressed = true
	weapons._unhandled_input(scroll)
	check(weapons.current_weapon == 1 and not player.get_node("gun").is_processing() and sword.visible, "Mouse wheel equips sword and disables gun firing")
	check(hud.get_node("%SwordSlot").get_theme_stylebox("panel") == hud.selected_style, "Right-side sword icon reflects the selected weapon")
	scroll.button_index = MOUSE_BUTTON_WHEEL_UP
	weapons._unhandled_input(scroll)
	check(weapons.current_weapon == 0, "Reverse mouse wheel switches back to gun")
	weapons.equip_weapon(1)
	weapons.aim_direction = Vector2.RIGHT
	var front = enemy_at(game, player.global_position + Vector2(24, 0))
	var rear = enemy_at(game, player.global_position + Vector2(-24, 0))
	var outside = enemy_at(game, player.global_position + Vector2(0, -50))
	var distant = enemy_at(game, player.global_position + Vector2(100, 0))
	await physics_frame
	await physics_frame
	check(sword.start_swing(Vector2.RIGHT), "Sword starts a swing toward the requested aim direction")
	check(not sword.start_swing(Vector2.RIGHT), "Attack cooldown prevents overlapping swings")
	weapons.set_guarding(true, Vector2.RIGHT)
	check(not weapons.is_guarding, "Player cannot guard in the middle of a swing")
	await create_timer(0.25).timeout
	check(front.health == 3, "A real sector collision deals one sword hit per target per swing")
	check(rear.health == 5 and outside.health == 5 and distant.health == 5, "Sword ignores targets behind, outside sector, or beyond reach")
	front.free()
	rear.free()
	outside.free()
	distant.free()
	await create_timer(0.2).timeout
	# Ordinary walls must prevent melee hits through solid terrain.
	front = enemy_at(game, player.global_position + Vector2(28, 0))
	var wall := StaticBody2D.new()
	wall.position = player.global_position + Vector2(13, 0)
	wall.collision_layer = 1
	var collision := CollisionShape2D.new()
	var rectangle := RectangleShape2D.new()
	rectangle.size = Vector2(4, 80)
	collision.shape = rectangle
	wall.add_child(collision)
	game.add_child(wall)
	await physics_frame
	await physics_frame
	sword.start_swing(Vector2.RIGHT)
	await create_timer(0.25).timeout
	check(front.health == 5, "Sword cannot hit an enemy through a solid wall")
	front.free()
	wall.free()
	await create_timer(0.2).timeout
	weapons.set_guarding(true, Vector2.RIGHT)
	var hp_before: float = player.real_hp
	check(player.receive_attack(10, player.global_position + Vector2(60, 0)), "Frontal blockable attack is blocked")
	check(player.real_hp == hp_before and weapons.guard_value == 80, "Successful block spends guard rather than health")
	check(hud.get_node("%GuardBar").value == 80, "Blue guard bar follows the player's resource")
	player.receive_attack(10, player.global_position + Vector2(-60, 0))
	check(player.real_hp == hp_before - 10 and weapons.guard_value == 80, "Attack from behind bypasses directional guard")
	player.take_damage(10)
	check(player.real_hp == hp_before - 20 and weapons.guard_value == 80, "Existing collision damage bypasses guard")
	var bullet = load("res://scene/bullet.tscn").instantiate()
	bullet.position = player.global_position + Vector2(60, 0)
	bullet.rotation = PI
	root.add_child(bullet)
	await create_timer(0.2).timeout
	check(not is_instance_valid(bullet) and player.real_hp == hp_before - 20 and weapons.guard_value == 60, "Right-button guard stops a real incoming bullet")
	player.receive_attack(10, player.global_position + Vector2(60, 0))
	player.receive_attack(10, player.global_position + Vector2(60, 0))
	player.receive_attack(10, player.global_position + Vector2(60, 0))
	check(weapons.guard_value == 0 and not weapons.is_guarding, "Guard breaks when its resource runs out")
	player.receive_attack(10, player.global_position + Vector2(60, 0))
	check(player.real_hp == hp_before - 30, "Broken guard cannot absorb another attack")
	Input.action_press("block")
	weapons.recover_guard(1.0)
	check(is_equal_approx(weapons.guard_value, 100.0 / 15.0) and not weapons.is_guarding, "Holding block during exhaustion keeps recovery running without defense")
	Input.action_release("block")
	weapons.set_guarding(false)
	weapons.recover_guard(1.0)
	check(is_equal_approx(weapons.guard_value, 200.0 / 15.0) and is_equal_approx(hud.get_node("%GuardBar").value, 200.0 / 15.0), "Releasing block restores guard and updates the HUD")
	weapons.set_guarding(true, Vector2.RIGHT)
	weapons.equip_weapon(0)
	check(not weapons.is_guarding and not sword.visible and player.get_node("gun").is_processing(), "Weapon switch cancels guard and only activates the selected weapon")
	weapons.equip_weapon(1)
	player.respawn_delay = 0.15
	kill_actor(player)
	check(not sword.visible and not weapons.is_guarding and not player.get_node("gun").is_processing(), "Death disables both weapons and guard")
	scroll.button_index = MOUSE_BUTTON_WHEEL_DOWN
	weapons._unhandled_input(scroll)
	check(weapons.current_weapon == 1, "Dead player cannot switch weapons")
	await create_timer(0.3).timeout
	check(not player.is_dead and weapons.guard_value == 100 and sword.visible and not player.get_node("gun").is_processing(), "Respawn restores guard and keeps the selected sword equipped")
	var remote = load("res://scene/maincharac.tscn").instantiate()
	remote.is_locally_controlled = false
	remote.position = Vector2(2500, -300)
	game.add_child(remote)
	remote.get_node("WeaponController")._unhandled_input(scroll)
	check(remote.get_node("WeaponController").current_weapon == 0 and not remote.get_node("gun").is_processing(), "Remote player ignores local scroll and weapon input")
	game.free()
	print("RESULT: ", failures.size(), " failures")
	quit(0 if failures.is_empty() else 1)

# Death fixtures now deplete one cell per hit, including duplicate-death coverage.
func kill_actor(actor: Node) -> void:
	for index in range(9):
		actor.take_damage(actor.max_hp)
		if actor.is_dead: return
