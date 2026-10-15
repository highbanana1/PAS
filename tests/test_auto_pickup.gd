extends SceneTree
var failures: Array[String] = []
func _initialize() -> void: run.call_deferred()
func check(ok: bool, label: String) -> void:
	print(("PASS: " if ok else "FAIL: ") + label)
	if not ok: failures.append(label)
func action(name: String) -> InputEventAction:
	var e := InputEventAction.new(); e.action = name; e.pressed = true; return e
func run() -> void:
	var world := Node2D.new(); root.add_child(world); current_scene = world
	var p = load("res://scene/maincharac.tscn").instantiate(); world.add_child(p); p.set_physics_process(false)
	p.get_weapon_controller().set_process(false)
	var input = p.get_node("LocalItemInput"); input.set_process(false)
	var c = p.get_inventory_component()
	check(c.selected and c.selected_index == 0 and c.has_method("toggle_auto_pickup"), "Game starts on slot 3 with configurable automatic pickup")
	if not c.has_method("toggle_auto_pickup"): world.free(); quit(1); return
	var Data = load("res://scene/script/items/health_item_data.gd")
	var drops: Array = []
	for index in range(4):
		drops.append(p.get_health_item_drop_component().spawn_item(Data.new(30), p.global_position + Vector2(2+index,0)))
	input.tick(0.1)
	check(c.auto_pickup_enabled and c.items.size() == 3 and drops[3].is_in_group("world_item_pickup"), "Automatic pickup fills free slots in nearest order and leaves overflow in world")
	input.handle_event(action("item_auto_pickup_toggle")); c.take_all_items(); input.tick(1)
	check(not c.auto_pickup_enabled and c.items.is_empty(), "T disables automatic pickup")
	input.handle_event(action("item_pickup"))
	check(c.items.size() == 1, "Manual F pickup works while automatic pickup is disabled")
	c.take_all_items(); var far = p.get_health_item_drop_component().spawn_item(Data.new(30),p.global_position+Vector2(100,0))
	input.handle_event(action("item_auto_pickup_toggle")); input.tick(1)
	check(c.auto_pickup_enabled and c.items.is_empty() and far.is_in_group("world_item_pickup"), "T re-enables pickup without extending pickup distance")
	far.global_position = p.global_position; p.is_locally_controlled = false; input.tick(1)
	check(c.items.is_empty(), "Remote actor never automatically picks up from local input")
	p.is_locally_controlled = true; p.real_hp = 10; p.take_damage(100); input.tick(1)
	check(c.items.is_empty(), "Dead actor cannot automatically pick up")
	p.respawn(p.spawn_position); input.tick(1)
	check(c.items.size() == 1 and c.auto_pickup_enabled and not input.held and c.items[0].remaining == 30, "Respawn permits nearby automatic pickup without resuming item use")
	var key := InputEventKey.new(); key.physical_keycode = KEY_T; key.pressed = true
	check(key.is_action_pressed("item_auto_pickup_toggle"), "T key is mapped to auto pickup toggle")
	world.free(); print("RESULT: ",failures.size()," failures"); quit(0 if failures.is_empty() else 1)
