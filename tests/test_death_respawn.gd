extends SceneTree

# Catches deletion instead of per-player death, global pauses, missed respawns,
# dead input/pickup, and scene reloads that reset the shared world.
var failures: Array[String] = []

func _initialize() -> void:
	_run.call_deferred()

func check(condition: bool, message: String) -> void:
	if condition:
		print("PASS: " + message)
	else:
		failures.append(message)
		push_error("FAIL: " + message)

func settle() -> void:
	for frame in range(4):
		await physics_frame
	await process_frame

func _run() -> void:
	var game: Node2D = load("res://scene/main.tscn").instantiate()
	root.add_child(game)
	current_scene = game
	var player = game.get_node("CharacterBody2D")
	var original_player_id: int = player.get_instance_id()
	var spawn_position: Vector2 = player.global_position
	var spawn_layer: int = player.collision_layer
	var spawn_mask: int = player.collision_mask
	var enemy = game.get_node("enemy")
	var original_enemy_id: int = enemy.get_instance_id()
	enemy.health = 3
	enemy.global_position = Vector2(300, -300)
	var table = game.get_node("wtable")
	var star = game.get_node("WinningPoint")
	var screen = game.get_node_or_null("DeathScreen")
	check(screen != null, "Death UI exists in main scene")
	if screen != null:
		check(not screen.visible, "Death UI starts hidden")
	# Exercise the original damage/death entry point rather than a test-only path.
	star._on_player_touch(player)
	player.global_position = Vector2(80, -80)
	player.take_damage(90)
	check(player.get("is_dead") == true, "Lethal damage enters an explicit dead state")
	await settle()
	check(is_instance_valid(player), "Player node survives death for independent respawn")
	if not is_instance_valid(player):
		game.free()
		print("RESULT: ", failures.size(), " failures")
		quit(1)
		return
	check(not paused, "Death never pauses the world")
	check(player.collision_layer == 0 and player.collision_mask == 0, "Dead player cannot collide or trigger pickups")
	check(not player.get_node("gun").is_processing(), "Dead player's gun cannot fire")
	check(not player.get_node("AnimatedSprite2D").visible, "Dead player visuals are hidden without removing camera")
	check(player.current_winning_point == null and not star.is_picked and star.ref == null, "Death drops a carried star")
	star._on_player_touch(player)
	check(not star.is_picked, "Dead players cannot pick up the dropped star")
	if screen != null:
		check(screen.visible, "Death UI becomes visible")
		check(screen.get_node("%Countdown").text == "5", "Countdown initially displays five seconds")
	var death_position: Vector2 = player.global_position
	var moving_bullet: Node2D = load("res://scene/bullet.tscn").instantiate()
	root.add_child(moving_bullet)
	moving_bullet.get_node("Area2D").set_deferred("monitoring", false)
	moving_bullet.rotation = 0
	var bullet_start: Vector2 = moving_bullet.position
	var enemy_start: Vector2 = enemy.global_position
	Input.action_press("right")
	Input.action_press("jump")
	Input.action_press("dash")
	Input.action_press("fire")
	await create_timer(1.15).timeout
	Input.action_release("right")
	Input.action_release("jump")
	Input.action_release("dash")
	Input.action_release("fire")
	check(player.global_position.is_equal_approx(death_position), "Dead player ignores movement, jump and dash")
	check(enemy.global_position.distance_to(enemy_start) > 1.0, "Enemy continues moving during countdown")
	check(is_instance_valid(moving_bullet) and moving_bullet.position.x > bullet_start.x + 100, "Existing bullet continues moving during countdown")
	if is_instance_valid(moving_bullet):
		moving_bullet.free()
	if screen != null:
		var shown: int = int(screen.get_node("%Countdown").text)
		check(shown > 0 and shown < 5, "Visible countdown decreases in real game time")
	player.take_damage(90)
	player._die_logic(0)
	await create_timer(4.05).timeout
	check(not player.is_dead and player.real_hp == 90, "Countdown automatically revives at full health despite duplicate death calls")
	check(player.get_instance_id() == original_player_id, "Respawn preserves player identity")
	check(enemy.get_instance_id() == original_enemy_id and enemy.health == 3, "Respawn preserves shared enemy state")
	check(player.collision_layer == spawn_layer and player.collision_mask == spawn_mask, "Respawn restores original collision filters")
	check(player.get_node("gun").is_processing() and player.get_node("AnimatedSprite2D").visible, "Respawn restores gun and visuals")
	check(player.global_position.distance_to(spawn_position) < 20.0, "Respawn returns to original spawn point")
	check(game.get_node("UILayer/PanelHP/TextureProgressBar3").value == 30, "Full health refreshes all three health bars")
	if screen != null:
		check(not screen.visible, "Death UI closes after respawn")
	# A delivered objective belongs to the table and must survive later deaths.
	star._on_player_touch(player)
	table._on_body_entered(player)
	check(table.wp == star and star.ref == table, "Existing star delivery still works")
	player.respawn_delay = 0.15
	player.take_damage(90)
	player._die_logic(0)
	await create_timer(0.3).timeout
	check(not player.is_dead and player.real_hp == 90, "A second death gets its own successful respawn")
	check(table.wp == star and star.ref == table, "Delivered objective survives death and respawn")
	# A second player's lifecycle must not drive the local player's overlay.
	var remote = load("res://scene/maincharac.tscn").instantiate()
	remote.is_locally_controlled = false
	remote.position = Vector2(900, -200)
	game.add_child(remote)
	remote.respawn_delay = 0.15
	remote.take_damage(90)
	check(remote.get("is_dead") == true, "Non-local player's damage API enters death without local input processing")
	check(not player.is_dead and not paused, "Other player's death does not affect local player or world")
	if screen != null:
		check(not screen.visible, "Other player's death does not show local death UI")
	await create_timer(0.3).timeout
	check(not remote.is_dead and remote.real_hp == 90 and not remote.get_node("gun").is_processing(), "Other player independently respawns without receiving local weapon input")
	game.free()
	print("RESULT: ", failures.size(), " failures")
	quit(0 if failures.is_empty() else 1)
