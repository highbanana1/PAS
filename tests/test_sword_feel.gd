extends SceneTree

var failures: Array[String] = []

func _initialize() -> void:
	_run.call_deferred()

func check(condition: bool, message: String) -> void:
	if condition:
		print("PASS: " + message)
	else:
		failures.append(message)
		print("FAIL: " + message)

func enemy_at(game: Node, point: Vector2) -> Node2D:
	var enemy = load("res://scene/enemy.tscn").instantiate()
	enemy.scale = Vector2(0.045, 0.045)
	enemy.position = point
	game.add_child(enemy)
	enemy.set_physics_process(false)
	return enemy

func advance(sword: Node, seconds: float) -> void:
	var remaining := seconds
	while remaining > 0.00001:
		var step := minf(remaining, 0.005)
		sword._physics_process(step)
		sword._process(step)
		remaining -= step

func feedback_count(kind: String) -> int:
	var count := 0
	for effect in get_nodes_in_group("combat_feedback"):
		if effect.get("kind") == kind:
			count += 1
	return count

func _run() -> void:
	var game = load("res://scene/main.tscn").instantiate()
	root.add_child(game)
	current_scene = game
	var player = game.get_node("CharacterBody2D")
	player.set_physics_process(false)
	player.global_position = Vector2(1500, -300)
	game.get_node("enemy").set_physics_process(false)
	var weapons = player.get_node("WeaponController")
	weapons.set_process(false)
	weapons.equip_weapon(1)
	weapons.aim_direction = Vector2.RIGHT
	var sword = player.get_node("Sword")
	sword.set_process(false)
	sword.set_physics_process(false)
	var target = enemy_at(game, sword.global_position + Vector2(24, 0))
	await physics_frame
	await physics_frame
	check(sword.start_swing(Vector2.RIGHT), "One click starts one slash")
	advance(sword, 0.02)
	check(target.health == 5, "Brief windup cannot damage targets before the blade moves")
	check(sword.global_rotation < -0.5, "Windup visibly draws the sword back")
	advance(sword, 0.09)
	check(target.health == 3, "Fast sweep damages the target once")
	check(feedback_count("hit") == 1, "A successful slash creates one local hit flash")
	if feedback_count("hit") == 1:
		var effect = get_nodes_in_group("combat_feedback")[0]
		var sprite = target.get_node("AnimatedSprite2D")
		var original_modulate: Color = sprite.modulate
		sprite.flip_h = not sprite.flip_h
		sprite.frame = sprite.sprite_frames.get_frame_count(sprite.animation) - 1
		effect._process(0.01)
		var flash = effect.get_child(0)
		check(flash.flip_h == sprite.flip_h and flash.texture == sprite.sprite_frames.get_frame_texture(sprite.animation, sprite.frame), "Hit flash follows the target's current frame and facing")
		check(sprite.modulate == original_modulate, "Hit flash leaves the target's original appearance untouched")
	advance(sword, 0.035)
	check(sword.is_swinging and sword.global_rotation > 0.5, "Sword follows through before recovering")
	var late = enemy_at(game, sword.global_position + Vector2(24, 0))
	await physics_frame
	await physics_frame
	advance(sword, 0.06)
	check(late.health == 5, "Recovery pose cannot damage a newly entering target")
	check(not sword.start_swing(Vector2.RIGHT), "Recovery cannot start an overlapping slash")
	advance(sword, 0.8)
	check(not sword.is_swinging and target.health == 3 and late.health == 5, "A single click ends without an automatic second attack")
	check(absf(sword.global_rotation) < 0.01, "Recovery smoothly returns to the aiming pose")
	check(not paused and Engine.time_scale == 1.0, "Attack feedback never pauses or slows the game world")
	weapons.set_guarding(true, Vector2.RIGHT)
	var hp_before: float = player.real_hp
	check(player.receive_attack(10, player.global_position + Vector2(60, 0)), "Existing directional block still absorbs frontal attacks")
	check(feedback_count("guard") == 1 and player.real_hp == hp_before and weapons.guard_value == 80, "Successful block produces sparks and consumes twenty guard")
	player.receive_attack(10, player.global_position + Vector2(-60, 0))
	check(feedback_count("guard") == 1, "An unblocked rear attack does not create false block sparks")
	await create_timer(0.4).timeout
	check(get_nodes_in_group("combat_feedback").is_empty(), "Temporary combat effects clean themselves up")
	weapons.set_guarding(false)
	sword.start_swing(Vector2.RIGHT)
	advance(sword, 0.02)
	weapons.equip_weapon(0)
	advance(sword, 0.3)
	check(not sword.is_swinging and late.health == 5, "Switching weapons cancels windup without a delayed hit")
	game.free()
	print("RESULT: ", failures.size(), " failures")
	quit(0 if failures.is_empty() else 1)
