extends SceneTree

# Catches automatic pickup when respawn re-enables a body already overlapping
# its released star, while still permitting deliberate re-entry and other players.
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
	for frame in range(5):
		await physics_frame
	await process_frame

func make_game() -> Node2D:
	var game: Node2D = load("res://scene/main.tscn").instantiate()
	root.add_child(game)
	current_scene = game
	game.get_node("CharacterBody2D").set_physics_process(false)
	game.get_node("enemy").set_physics_process(false)
	return game

func _run() -> void:
	var game := make_game()
	var player = game.get_node("CharacterBody2D")
	var star = game.get_node("WinningPoint")
	player.global_position = Vector2(1000, -80)
	player.spawn_position = Vector2(1000, -80)
	player.respawn_delay = 0.15
	await settle()
	star._on_player_touch(player)
	star._process(0.0)
	kill_actor(player)
	var released_position: Vector2 = star.global_position
	await create_timer(0.35).timeout
	check(not player.is_dead, "Player revives normally at an overlapping spawn point")
	check(not star.is_picked and star.ref == null and player.current_winning_point == null, "Respawn overlap does not automatically reacquire the star")
	check(star.global_position.is_equal_approx(released_position), "Released star remains at death location with no gravity or respawn movement")
	player.global_position = Vector2(1200, -80)
	await settle()
	player.global_position = released_position
	await settle()
	check(star.ref == player and star.is_picked, "Leaving and re-entering permits deliberate pickup")
	game.free()
	await settle()
	game = make_game()
	player = game.get_node("CharacterBody2D")
	star = game.get_node("WinningPoint")
	player.global_position = Vector2(1000, -80)
	player.spawn_position = Vector2(1300, -80)
	player.respawn_delay = 0.15
	await settle()
	star._on_player_touch(player)
	kill_actor(player)
	released_position = star.global_position
	await create_timer(0.35).timeout
	check(not star.is_picked and star.global_position.is_equal_approx(released_position), "Distant respawn never teleports the star")
	player.global_position = released_position
	await settle()
	check(star.ref == player and star.is_picked, "Returning from a distant spawn can pick up on first approach")
	# A different living player must not be blocked by the former carrier's death.
	player.respawn_delay = 0.5
	kill_actor(player)
	var other = load("res://scene/maincharac.tscn").instantiate()
	other.is_locally_controlled = false
	other.scale = Vector2(0.03, 0.03)
	other.position = star.global_position
	game.add_child(other)
	await settle()
	check(star.ref == other and other.current_winning_point == star, "Another living player can pick up while the former carrier is dead")
	await create_timer(0.6).timeout
	check(star.ref == other and player.current_winning_point == null, "Former carrier's respawn does not steal another player's star")
	game.free()
	print("RESULT: ", failures.size(), " failures")
	quit(0 if failures.is_empty() else 1)

# Death fixtures now deplete one cell per hit, including duplicate-death coverage.
func kill_actor(actor: Node) -> void:
	for index in range(9):
		actor.take_damage(actor.max_hp)
		if actor.is_dead: return
