extends SceneTree

# Real collision regression: world hits must free the projectile without
# losing enemy damage or destroying a shot against its own shooter.
var failures: Array[String] = []

func _initialize() -> void:
	_run.call_deferred()

func check(condition: bool, message: String) -> void:
	if condition:
		print("PASS: " + message)
	else:
		failures.append(message)
		push_error("FAIL: " + message)

func make_bullet(at_position: Vector2) -> Node2D:
	var bullet: Node2D = load("res://scene/bullet.tscn").instantiate()
	bullet.position = at_position
	root.add_child(bullet)
	return bullet

func _run() -> void:
	var wall := StaticBody2D.new()
	wall.collision_layer = 1
	wall.position = Vector2(140, 0)
	var wall_shape := CollisionShape2D.new()
	var rectangle := RectangleShape2D.new()
	rectangle.size = Vector2(20, 100)
	wall_shape.shape = rectangle
	wall.add_child(wall_shape)
	root.add_child(wall)
	var bullet := make_bullet(Vector2.ZERO)
	await create_timer(0.35).timeout
	check(not is_instance_valid(bullet), "Bullet disappears on a real wall collision")
	if is_instance_valid(bullet):
		bullet.free()
	wall.free()
	var enemy = load("res://scene/enemy.tscn").instantiate()
	enemy.scale = Vector2(0.045, 0.045)
	enemy.position = Vector2(140, -4)
	root.add_child(enemy)
	enemy.set_physics_process(false)
	bullet = make_bullet(Vector2.ZERO)
	await create_timer(0.35).timeout
	check(not is_instance_valid(bullet), "Bullet disappears on a real enemy collision")
	check(enemy.health == 4, "Enemy collision still deals exactly one damage")
	if is_instance_valid(bullet):
		bullet.free()
	enemy.free()
	var player = load("res://scene/maincharac.tscn").instantiate()
	player.scale = Vector2(0.03, 0.03)
	player.position = Vector2(1000, 0)
	root.add_child(player)
	player.set_physics_process(false)
	var gun = player.get_node("gun")
	gun.set_process(false)
	Input.action_press("fire")
	player.get_node("WeaponController")._process(0.0)
	Input.action_release("fire")
	var fired = get_nodes_in_group("bullet")
	check(fired.size() == 5 and fired.all(func(shot): return shot.shooter == player), "Gun records the firing player on its projectile")
	for shot in fired:
		shot.free()
	bullet = make_bullet(player.position)
	bullet.set_process(false)
	bullet.set("shooter", player)
	bullet._on_area_2d_body_entered(player)
	await process_frame
	check(is_instance_valid(bullet), "Bullet ignores contact with its own shooter")
	if is_instance_valid(bullet):
		bullet.free()
	var other := CharacterBody2D.new()
	other.add_to_group("player")
	root.add_child(other)
	bullet = make_bullet(Vector2(2000, 0))
	bullet.set_process(false)
	bullet.set("shooter", player)
	bullet._on_area_2d_body_entered(other)
	await process_frame
	check(not is_instance_valid(bullet), "Bullet disappears on another player rather than ignoring all players")
	if is_instance_valid(bullet):
		bullet.free()
	other.free()
	player.free()
	print("RESULT: ", failures.size(), " failures")
	quit(0 if failures.is_empty() else 1)
