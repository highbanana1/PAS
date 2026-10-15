extends SceneTree
var failures: Array[String] = []
func _initialize() -> void: run.call_deferred()
func check(ok: bool, label: String) -> void:
	print(("PASS: " if ok else "FAIL: ") + label)
	if not ok: failures.append(label)
func run() -> void:
	var world := Node2D.new(); root.add_child(world); current_scene = world
	var p = load("res://scene/maincharac.tscn").instantiate()
	p.is_locally_controlled = false; world.add_child(p); p.set_physics_process(false)
	check(p.has_method("get_health_item_drop_component"), "Actor exposes independent world drop component")
	if not p.has_method("get_health_item_drop_component"): world.free(); quit(1); return
	var Data = load("res://scene/script/items/health_item_data.gd")
	var drop = p.get_health_item_drop_component(); var c = p.get_health_item_component()
	var placed = load("res://scene/health_item_pickup.tscn").instantiate(); world.add_child(placed)
	placed.global_position = p.global_position
	check(placed.can_pick_up(p), "Independently placed item scene starts with a full reserve")
	placed.free()
	var partial = Data.new(30); partial.remaining = 12
	var ground = drop.spawn_item(partial, p.global_position + Vector2(100,0))
	check(not ground.try_pick_up(p), "Distant pickup is rejected")
	ground.global_position = p.global_position
	check(ground.try_pick_up(p) and c.items[0].remaining == 12, "Nearby pickup transfers remaining reserve unchanged")
	check(not ground.try_pick_up(p) and c.items.size() == 1, "Repeated pickup cannot duplicate item")
	await process_frame
	c.add_item(Data.new(30)); p.real_hp = 10; p.take_damage(100)
	var drops = get_nodes_in_group("health_item_pickup")
	check(p.is_dead and c.items.is_empty() and drops.size() == 2, "Death drops every item and empties inventory")
	var reserves: Array = []
	for item in drops: reserves.append(item.item.remaining)
	reserves.sort()
	check(reserves == [12.0,30.0], "Death preserves each separate reserve")
	check(not drops[0].try_pick_up(p), "Dead character cannot pick up items")
	p._die_logic(0)
	check(get_nodes_in_group("health_item_pickup").size() == 2, "Repeated death does not duplicate drops")
	p.respawn(p.spawn_position)
	check(c.items.is_empty() and p.real_hp == 150, "Respawn has five cells and no automatically returned items")
	drops[0].global_position = p.global_position
	check(drops[0].try_pick_up(p), "Respawned character can manually recover dropped item")
	await process_frame
	var enemy = load("res://scene/enemy.tscn").instantiate(); world.add_child(enemy); enemy.set_physics_process(false)
	enemy.health_item_drop_chance = 0; var before := get_nodes_in_group("health_item_pickup").size()
	enemy.hurt(100); await process_frame
	check(get_nodes_in_group("health_item_pickup").size() == before, "Zero enemy drop chance produces no item")
	enemy = load("res://scene/enemy.tscn").instantiate(); world.add_child(enemy); enemy.set_physics_process(false)
	enemy.health_item_drop_chance = 1; enemy.hurt(100); enemy.hurt(100); await process_frame
	check(get_nodes_in_group("health_item_pickup").size() == before + 1, "Guaranteed enemy loot drops once")
	world.free(); print("RESULT: ", failures.size(), " failures"); quit(0 if failures.is_empty() else 1)
