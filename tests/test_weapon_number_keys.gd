extends SceneTree
var failures: Array[String] = []
func _initialize() -> void: run.call_deferred()
func check(ok: bool, text: String) -> void:
	print(("PASS: " if ok else "FAIL: ") + text)
	if not ok: failures.append(text)
func key(code: Key, pressed: bool = true, echo: bool = false) -> InputEventKey:
	var event := InputEventKey.new()
	event.physical_keycode = code
	event.pressed = pressed
	event.echo = echo
	return event
func run() -> void:
	var player = load("res://scene/maincharac.tscn").instantiate()
	root.add_child(player); player.set_physics_process(false)
	var weapons = player.get_weapon_controller()
	weapons.set_process(false)
	weapons._unhandled_input(key(KEY_2))
	check(weapons.current_weapon == 1 and player.get_node("Sword").active and not player.get_node("gun").active, "Physical key 2 selects only the sword")
	weapons._unhandled_input(key(KEY_1))
	check(weapons.current_weapon == 0 and player.get_node("gun").active and not player.get_node("Sword").active, "Physical key 1 selects only the gun")
	weapons.equip_weapon(1)
	weapons.attack(Vector2.RIGHT)
	weapons._unhandled_input(key(KEY_2,true,true))
	check(player.get_node("Sword").is_swinging, "Held number key repeat cannot cancel a swing")
	weapons._unhandled_input(key(KEY_1,false))
	check(weapons.current_weapon == 1, "Number-key release does not switch equipment")
	weapons.equip_weapon(0)
	player.is_dead = true
	weapons._unhandled_input(key(KEY_2))
	check(weapons.current_weapon == 0, "Dead actor ignores number selection")
	player.is_dead = false
	player.is_locally_controlled = false
	weapons._unhandled_input(key(KEY_2))
	check(weapons.current_weapon == 0, "Remote actor ignores local number selection")
	player.is_locally_controlled = true
	var wheel := InputEventMouseButton.new()
	wheel.button_index = MOUSE_BUTTON_WHEEL_DOWN; wheel.pressed = true
	weapons._unhandled_input(wheel)
	check(weapons.current_weapon == 1, "Mouse wheel selection remains available")
	player.free()
	print("RESULT: ", failures.size(), " failures")
	quit(0 if failures.is_empty() else 1)
