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


func settle() -> void:
	for frame in range(4):
		await physics_frame
	await process_frame


func make_game() -> Node2D:
	var game: Node2D = load("res://scene/main.tscn").instantiate()
	root.add_child(game)
	current_scene = game
	game.get_node("CharacterBody2D").set_physics_process(false)
	game.get_node("CharacterBody2D/gun").set_process(false)
	game.get_node("enemy").set_physics_process(false)
	game.get_node("WinningPoint").set_process(false)
	return game


func _run() -> void:
	var game := make_game()
	var player = game.get_node("CharacterBody2D")
	var star = game.get_node("WinningPoint")
	var table = game.get_node("wtable")
	var hp_before: float = player.real_hp
	player.global_position = table.global_position + Vector2(0, -20)
	await settle()
	check(table.wp == null and player.current_winning_point == null, "Touching the table empty-handed is safe")
	table._on_body_entered(game.get_node("enemy"))
	check(table.wp == null, "Table ignores non-player bodies")
	player.global_position = star.global_position
	await settle()
	check(star.is_picked and star.ref == player and player.current_winning_point == star, "Real collision picks up the star")
	star._process(0.0)
	check(is_equal_approx(star.global_position.x, player.global_position.x), "Carried star follows player")
	player.global_position = table.global_position + Vector2(0, -20)
	await settle()
	check(table.wp == star and star.ref == table and player.current_winning_point == null, "Real table collision transfers ownership and clears carrier")
	player.global_position += Vector2(80, 0)
	table.global_position += Vector2(20, 0)
	star._process(0.0)
	check(is_equal_approx(star.global_position.x, table.global_position.x), "Delivered star follows moving table rather than departing player")
	check(abs(star.global_position.y - table.global_position.y - star.float_offset_y) <= 2.51, "Original floating height and bobbing are preserved")
	star._on_player_touch(player)
	check(star.ref == table and player.current_winning_point == null, "Delivered star cannot be picked up again")
	check(player.real_hp == hp_before, "Interaction does not change player health")
	game.free()
	await settle()
	game = make_game()
	player = game.get_node("CharacterBody2D")
	star = game.get_node("WinningPoint")
	table = game.get_node("wtable")
	player.global_position = table.global_position + Vector2(0, -20)
	await settle()
	star.global_position = player.global_position
	await settle()
	check(table.wp == star and star.ref == table and player.current_winning_point == null, "Pickup while already inside table also delivers")
	game.free()
	await settle()
	game = make_game()
	player = game.get_node("CharacterBody2D")
	star = game.get_node("WinningPoint")
	player.global_position = star.global_position
	await settle()
	player.free()
	star._process(0.0)
	check(not is_instance_valid(star.ref), "Freed carrier is handled safely")
	game.free()
	print("RESULT: ", failures.size(), " failures")
	quit(0 if failures.is_empty() else 1)
