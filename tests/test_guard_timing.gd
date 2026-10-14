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

func _run() -> void:
	var game = load("res://scene/main.tscn").instantiate()
	root.add_child(game)
	current_scene = game
	var player = game.get_node("CharacterBody2D")
	player.set_physics_process(false)
	game.get_node("enemy").set_physics_process(false)
	var weapons = player.get_node("WeaponController")
	weapons.set_process(false)
	weapons.equip_weapon(1)
	var bar = game.get_node("CombatHUD/%GuardBar")
	weapons.set_guarding(true, Vector2.RIGHT)
	weapons.recover_guard(5.0)
	check(is_equal_approx(weapons.guard_value, 50.0) and weapons.is_guarding, "Five seconds of guarding consumes half the meter")
	check(is_equal_approx(bar.value, 50.0), "HUD follows continuous guard drain")
	weapons.recover_guard(4.9)
	check(is_equal_approx(weapons.guard_value, 1.0) and weapons.is_guarding, "Guard remains usable immediately before ten seconds")
	weapons.recover_guard(0.1)
	check(weapons.guard_value == 0.0 and not weapons.is_guarding, "Ten seconds empties guard and lowers the sword")
	Input.action_press("block")
	weapons.set_guarding(true, Vector2.RIGHT)
	weapons.recover_guard(2.0)
	check(weapons.guard_value == 0.0 and not weapons.is_guarding, "Holding block after exhaustion cannot regenerate or restart guard")
	Input.action_release("block")
	weapons.recover_guard(7.5)
	check(is_equal_approx(weapons.guard_value, 50.0), "Releasing guard restores half the meter in 7.5 seconds")
	weapons.recover_guard(7.5)
	check(weapons.guard_value == 100.0 and bar.value == 100.0, "Empty guard fully recovers in fifteen seconds")
	weapons.recover_guard(30.0)
	check(weapons.guard_value == 100.0, "Recovery never exceeds a full meter")
	weapons.set_guarding(true, Vector2.RIGHT)
	var hp: float = player.real_hp
	check(player.receive_attack(10, player.global_position + Vector2(40, 0)), "Frontal attacks remain blockable")
	check(weapons.guard_value == 80.0 and player.real_hp == hp, "Blocking an attack costs twenty guard, twenty percent less than before")
	weapons.recover_guard(2.0)
	check(weapons.guard_value == 60.0, "Time drain continues after blocking an attack")
	player.receive_attack(10, player.global_position - Vector2(40, 0))
	check(weapons.guard_value == 60.0 and player.real_hp == hp - 10, "Rear attacks still bypass guard without spending its resource")
	weapons.set_guarding(false)
	weapons.recover_guard(3.0)
	check(is_equal_approx(weapons.guard_value, 80.0), "Partial recovery uses the same fifteen-second rate")
	weapons.equip_weapon(0)
	weapons.recover_guard(3.0)
	check(weapons.guard_value == 100.0, "Guard recovers while the gun is equipped")
	weapons.equip_weapon(1)
	weapons.guard_value = 10.0
	weapons.set_guarding(true, Vector2.RIGHT)
	check(player.receive_attack(10, player.global_position + Vector2(40, 0)) and weapons.guard_value == 0.0 and not weapons.is_guarding, "A final block clamps the meter at zero and breaks guard")
	weapons.recover_guard(3.0)
	player.get_node("Sword").start_swing(Vector2.RIGHT)
	weapons.recover_guard(3.0)
	check(is_equal_approx(weapons.guard_value, 40.0), "Using the sword without guarding allows recovery")
	player.is_dead = true
	weapons.suspend()
	weapons.recover_guard(5.0)
	check(is_equal_approx(weapons.guard_value, 40.0), "Dead players do not change guard through the timer")
	player.is_dead = false
	weapons.reset_after_respawn()
	weapons.set_guarding(true, Vector2.RIGHT)
	for index in range(600):
		weapons.recover_guard(1.0 / 60.0)
	check(weapons.guard_value == 0.0 and not weapons.is_guarding, "Small frame steps also exhaust guard at ten seconds")
	game.free()
	print("RESULT: ", failures.size(), " failures")
	quit(0 if failures.is_empty() else 1)
