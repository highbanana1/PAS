extends SceneTree
var failures: Array[String] = []
func _initialize() -> void: run.call_deferred()
func check(ok: bool, label: String) -> void:
	print(("PASS: " if ok else "FAIL: ") + label)
	if not ok: failures.append(label)
func obstacle(world: Node, y: float, layer: int) -> void:
	var body := StaticBody2D.new(); body.position = Vector2(0,y); body.collision_layer = layer; body.collision_mask = 0
	var shape := CollisionShape2D.new(); var rect := RectangleShape2D.new(); rect.size = Vector2(300,10)
	shape.shape = rect; body.add_child(shape); world.add_child(body)
func run() -> void:
	var world := Node2D.new(); root.add_child(world); current_scene = world
	obstacle(world,50,2); obstacle(world,90,8); obstacle(world,180,1)
	var health = load("res://scene/health_item_pickup.tscn").instantiate()
	var jump = load("res://scene/jump_item_pickup.tscn").instantiate()
	world.add_child(health); world.add_child(jump)
	check(health is RigidBody2D and jump is RigidBody2D, "All consumable pickups use real rigid body physics")
	if not health is RigidBody2D or not jump is RigidBody2D: world.free(); quit(1); return
	check(health.collision_layer == 0 and health.collision_mask == 1 and jump.collision_mask == 1, "Pickups collide only with environment and expose no actor collision layer")
	for frame in range(20): await physics_frame
	check(health.position.y > 10 and jump.position.y > 10, "Health and jump items accelerate downward under gravity")
	for frame in range(100): await physics_frame
	check(health.position.y > 140 and health.position.y < 180 and jump.position.y > 140 and jump.position.y < 180, "Pickups pass through actor and enemy layers then settle on environment")
	check(absf(health.linear_velocity.y) < 1 and absf(jump.linear_velocity.y) < 1, "Ground contact stops falling without sinking")
	check(health.position.distance_to(jump.position) < 2, "Pickups do not collide with one another")
	world.free(); print("RESULT: ",failures.size()," failures"); quit(0 if failures.is_empty() else 1)
