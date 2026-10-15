extends SceneTree
var failures: Array[String] = []
func _initialize() -> void: run.call_deferred()
func check(ok: bool, label: String) -> void:
	print(("PASS: " if ok else "FAIL: ") + label)
	if not ok: failures.append(label)
func action(name: String, pressed: bool = true) -> InputEventAction:
	var event := InputEventAction.new(); event.action = name; event.pressed = pressed; return event
func run() -> void:
	var game = load("res://scene/main.tscn").instantiate(); root.add_child(game); current_scene = game
	var p = game.get_node("CharacterBody2D"); p.set_physics_process(false)
	game.get_node("enemy").set_physics_process(false); p.get_weapon_controller().set_process(false)
	check(p.has_node("LocalItemInput"), "Player exposes local item input adapter")
	if not p.has_node("LocalItemInput"): game.free(); quit(1); return
	var input = p.get_node("LocalItemInput"); input.set_process(false)
	p.health_item_use_duration = 2; p.health_item_hold_threshold = 0.3
	check(input.hold_threshold == 0.3 and p.get_health_item_component().use_duration == 2, "Actor Inspector properties forward to independent item timing")
	var key := InputEventKey.new(); key.physical_keycode = KEY_3; key.pressed = true
	check(key.is_action_pressed("item_select_1"), "Physical 3 key maps to item selection")
	key.physical_keycode = KEY_E
	check(key.is_action_pressed("item_use"), "Physical E key maps to selected item use")
	key.physical_keycode = KEY_F
	check(key.is_action_pressed("item_pickup"), "Physical F key maps to item pickup")
	var c = p.get_health_item_component(); var Data = load("res://scene/script/items/health_item_data.gd")
	var pickup = p.get_health_item_drop_component().spawn_item(Data.new(30), p.global_position)
	input.handle_event(action("item_pickup"))
	check(c.items.size() == 1 and not pickup.is_in_group("health_item_pickup"), "F picks up the closest item")
	p.real_hp = 120
	input.handle_event(action("item_select_1")); input.tick(0.2); input.handle_event(action("item_select_1",false))
	check(c.selected and c.items[0].remaining == 30 and p.real_hp == 120, "Short 3 selects without using reserve")
	var hud = game.get_node("CombatHUD")
	check(hud.get_node("%HealthItemProgress").value == 30 and hud.get_node("%HealthItemIcon").visible, "HUD displays reserve and supplied item image")
	input.handle_event(action("item_select_1")); input.tick(0.3); input.tick(1)
	check(p.real_hp == 135 and c.items[0].remaining == 15, "Holding 3 heals after threshold at fifteen HP per second")
	input.handle_event(action("item_select_1",false)); input.tick(1)
	check(p.real_hp == 135 and not c.using_continuously, "Releasing 3 stops healing")
	input.handle_event(action("item_use"))
	check(p.max_hp == 150 and c.items[0].remaining == 15, "E rejects a partly used selected item")
	input.handle_event(action("item_select_1")); input.tick(0.3)
	p.get_weapon_controller().equip_weapon(1); input.tick(1)
	check(not c.selected and p.real_hp == 135, "Weapon selection cancels continuous use and item selection")
	c.take_all_items(); c.add_item(Data.new(30)); input.handle_event(action("item_select_1")); input.handle_event(action("item_select_1",false))
	input.handle_event(action("item_use"))
	check(p.max_hp == 180 and p.real_hp == 165 and c.items.is_empty(), "Selected full item E expands exactly one cell and consumes item")
	c.add_item(Data.new(30)); input.handle_event(action("item_select_1")); input.tick(0.3)
	p.real_hp = 10; p.take_damage(100); p.respawn(p.spawn_position); input.tick(1)
	check(c.items.is_empty() and not input.held and not c.using_continuously and p.real_hp == 150, "Death drops inventory and respawn never resumes held healing")
	p.is_locally_controlled = false
	check(not input.handle_event(action("item_pickup")) and not input.handle_event(action("item_select_1")), "Remote actors ignore local item input")
	game.free(); print("RESULT: ", failures.size(), " failures"); quit(0 if failures.is_empty() else 1)
