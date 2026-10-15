extends SceneTree
var failures: Array[String] = []
func _initialize() -> void: run.call_deferred()
func check(ok: bool, text: String) -> void:
	print(("PASS: " if ok else "FAIL: ") + text)
	if not ok: failures.append(text)
func hit_effects_for(actor: Node2D) -> int:
	var count := 0
	for effect in get_nodes_in_group("combat_feedback"):
		if effect.kind == "hit" and effect._target != null and effect._target.get_ref() == actor.get_node("AnimatedSprite2D"):
			count += 1
	return count
func run() -> void:
	var game = load("res://scene/main.tscn").instantiate()
	root.add_child(game); current_scene = game
	var player = game.get_node("CharacterBody2D")
	player.global_position = Vector2(1500,-300)
	player.set_physics_process(false); player.get_weapon_controller().set_process(false)
	game.get_node("enemy").set_physics_process(false)
	var enemy = load("res://scene/enemy.tscn").instantiate()
	enemy.scale = Vector2(0.045,0.045); enemy.position = player.position+Vector2(24,0)
	game.add_child(enemy); enemy.set_physics_process(false)
	check(player.has_method("get_hurt_presentation") and enemy.has_method("get_hurt_presentation"), "Player and enemy expose their separate hurt presentations")
	if not player.has_method("get_hurt_presentation") or not enemy.has_method("get_hurt_presentation"):
		game.free(); quit(1); return
	var player_hurt = player.get_hurt_presentation()
	var enemy_hurt = enemy.get_hurt_presentation()
	var sprite = player.get_node("AnimatedSprite2D")
	var original_rotation: float = sprite.rotation
	var original_material = sprite.material
	var original_color: Color = sprite.self_modulate
	var enemy_scale: Vector2 = enemy.get_node("AnimatedSprite2D").scale
	await physics_frame
	await physics_frame
	# Finish scene startup before testing a moving projectile.
	await create_timer(0.2).timeout
	var bullet = load("res://scene/bullet.tscn").instantiate()
	bullet.shooter = player; bullet.position = enemy.position-Vector2(60,0)
	root.add_child(bullet)
	await create_timer(0.12).timeout
	check(enemy.health == 4 and enemy_hurt.is_playing, "A real bullet triggers the enemy hurt reaction")
	check(hit_effects_for(enemy) == 1 and not player_hurt.is_playing, "Bullet creates one enemy flash without invoking player animation")
	await create_timer(0.25).timeout
	check(enemy.get_node("AnimatedSprite2D").scale == enemy_scale, "Enemy restores its normal appearance after the reaction")
	player.get_weapon_controller().equip_weapon(1)
	player.get_weapon_controller().attack(Vector2.RIGHT)
	await create_timer(0.1).timeout
	check(enemy.health == 2 and enemy_hurt.is_playing, "A real sword hit triggers the same enemy hurt reaction")
	check(hit_effects_for(enemy) == 1, "Sword no longer doubles target feedback through the attacker")
	var position_before: Vector2 = player.global_position
	var velocity_before: Vector2 = player.velocity
	player.receive_attack(10,player.global_position+Vector2(60,0),true)
	check(player_hurt.is_playing and player.real_hp == 140, "Player damage starts its own hurt animation")
	player_hurt.set_process(false); player_hurt._process(0.06)
	check(sprite.material != original_material and sprite.rotation != original_rotation, "Player flashes white and leans back visually")
	player_hurt._process(0.1)
	check(sprite.self_modulate.a < original_color.a, "Player hurt animation has a brief flicker stage")
	check(player.global_position == position_before and player.velocity == velocity_before and not paused and Engine.time_scale == 1.0, "Player animation does not move the body or pause the world")
	player_hurt._process(1.0)
	check(not player_hurt.is_playing and sprite.material == original_material and sprite.rotation == original_rotation and sprite.self_modulate == original_color, "Player restores its original appearance after hurt")
	await create_timer(0.2).timeout
	player.get_weapon_controller().set_guarding(true,Vector2.RIGHT)
	player.receive_attack(10,player.global_position+Vector2(60,0),true)
	check(not player_hurt.is_playing and player.real_hp == 140, "Successful guard never plays a player damage animation")
	player.get_weapon_controller().set_guarding(false)
	player.take_damage(10)
	check(player_hurt.is_playing, "Unblockable contact-style damage also plays the player animation")
	kill_actor(player)
	check(player.is_dead and not player_hurt.is_playing and sprite.material == original_material and sprite.self_modulate == original_color, "Death clears hurt presentation without changing the death flow")
	game.free()
	print("RESULT: ", failures.size(), " failures")
	quit(0 if failures.is_empty() else 1)

# Death fixtures now deplete one cell per hit, including duplicate-death coverage.
func kill_actor(actor: Node) -> void:
	for index in range(9):
		actor.take_damage(actor.max_hp)
		if actor.is_dead: return
