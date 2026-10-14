extends SceneTree
var failures: Array[String] = []
func _initialize() -> void: run.call_deferred()
func check(ok: bool, label: String) -> void:
	print(("PASS: " if ok else "FAIL: ") + label)
	if not ok: failures.append(label)
func run() -> void:
	var player = load("res://scene/maincharac.tscn").instantiate()
	player.is_locally_controlled = false
	root.add_child(player)
	check(player.has_method("get_motor"), "Player exposes movement independent of keyboard input")
	if not player.has_method("get_motor"):
		player.free(); quit(1); return
	player.set_physics_process(false)
	var Motor = load("res://scene/script/components/character_motor.gd")
	var body := CharacterBody2D.new()
	body.name = "RobotWithoutPlayerScript"
	var shape := CollisionShape2D.new()
	var rect := RectangleShape2D.new(); rect.size = Vector2(10,20)
	shape.shape = rect; body.add_child(shape); root.add_child(body)
	var motor = Motor.new(); body.add_child(motor); motor.configure(body)
	var floor_body := StaticBody2D.new()
	floor_body.position = Vector2(0,100)
	var floor_shape := CollisionShape2D.new()
	var floor_rect := RectangleShape2D.new(); floor_rect.size = Vector2(2000,20)
	floor_shape.shape = floor_rect; floor_body.add_child(floor_shape); root.add_child(floor_body)
	for frame in range(45):
		await physics_frame
		motor.tick(1.0/60.0, Vector2.ZERO); body.move_and_slide()
	check(body.is_on_floor(), "Motor gravity settles a real body on a floor")
	var before: float = body.position.x
	for frame in range(6):
		await physics_frame
		motor.tick(1.0/60.0, Vector2.RIGHT); body.move_and_slide()
	check(is_equal_approx(body.velocity.x,150.0) and body.position.x > before + 10.0, "Explicit movement command drives real horizontal motion at original speed")
	motor.request_jump(); motor.tick(0.0,Vector2.ZERO)
	check(body.velocity.y == -400.0 and motor.jump_count == 0, "One jump applies the original impulse")
	body.move_and_slide()
	await physics_frame
	motor.tick(1.0/60.0,Vector2.ZERO); body.move_and_slide()
	motor.request_jump(); motor.tick(0.0,Vector2.ZERO)
	check(body.velocity.y > -400.0 and motor.jump_count == 0, "Airborne jump cannot reset the impulse")
	motor.request_dash(Vector2.RIGHT); motor.tick(0.01,Vector2.RIGHT)
	check(motor.is_dashing and not motor.can_dash and body.velocity == Vector2(360,0), "Dash command retains speed and consumes dash readiness")
	motor.tick(0.1,Vector2.ZERO)
	check(body.velocity.y == 0.0 and motor.is_dashing, "Dash suppresses gravity during its original duration")
	motor.tick(0.1,Vector2.ZERO)
	check(not motor.is_dashing, "Dash ends after 0.2 seconds")
	for frame in range(90):
		await physics_frame
		motor.tick(1.0/60.0,Vector2.ZERO); body.move_and_slide()
	check(body.is_on_floor() and motor.can_dash and motor.jump_count == 1, "Landing restores jump and dash readiness")
	motor.request_dash(Vector2.LEFT); motor.tick(0.01,Vector2.LEFT)
	motor.reset_state()
	check(body.velocity == Vector2.ZERO and motor.can_dash and not motor.is_dashing and motor.jump_count == 1, "Respawn reset clears all movement state")
	Input.action_press("right")
	var player_before: Vector2 = player.global_position
	player._physics_process(1.0/60.0)
	check(player.global_position == player_before and player.get_motor().can_dash, "Remote actor ignores local keyboard input")
	Input.action_release("right")
	player.get_motor().tick(1.0/60.0,Vector2.LEFT)
	check(player.velocity.x == -150.0 and motor.can_dash, "Remote actor accepts explicit commands without sharing motor state")
	motor.reset_state(); motor.request_dash(Vector2.LEFT); motor.tick(0.01,Vector2.ZERO)
	check(body.velocity.x == -360.0, "A standalone dash command honors its direction without a matching movement command")
	motor.reset_state(); motor.request_dash(Vector2(1,1)); motor.tick(0.01,Vector2.ZERO)
	check(is_equal_approx(body.velocity.length(),360.0) and is_equal_approx(body.velocity.x,body.velocity.y), "Standalone diagonal dash uses the requested normalized direction")
	body.free(); floor_body.free(); player.free()
	print("RESULT: ", failures.size(), " failures")
	quit(0 if failures.is_empty() else 1)
