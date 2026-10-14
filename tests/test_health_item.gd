extends SceneTree
var failures: Array[String] = []
func _initialize() -> void: run.call_deferred()
func check(ok: bool, label: String) -> void:
	print(("PASS: " if ok else "FAIL: ") + label)
	if not ok: failures.append(label)
func run() -> void:
	var p = load("res://scene/maincharac.tscn").instantiate()
	p.is_locally_controlled = false; root.add_child(p); p.set_physics_process(false)
	check(p.has_method("get_health_item_component"), "Actor exposes independent health item component")
	if not p.has_method("get_health_item_component"): p.free(); quit(1); return
	var Data = load("res://scene/script/items/health_item_data.gd")
	var c = p.get_health_item_component()
	p.real_hp = 120; c.add_item(Data.new(30)); c.select_item()
	check(c.use_selected() and p.max_hp == 180 and p.real_hp == 150 and c.items.is_empty(), "Full item expands maximum and current health by one cell")
	var partial = Data.new(30); partial.remaining = 15; c.add_item(partial)
	check(not c.use_selected() and partial.remaining == 15 and p.max_hp == 180, "Partial item cannot expand capacity")
	c.begin_continuous_use(); c.tick_continuous_use(1)
	check(p.real_hp == 165 and c.items.is_empty(), "One second consumes fifteen stored HP and heals fifteen")
	c.add_item(Data.new(30)); p.real_hp = 180; c.begin_continuous_use(); c.tick_continuous_use(1)
	check(c.items[0].remaining == 30, "Full health never wastes healing reserve")
	p.max_hp = 240; p.real_hp = 200
	check(not c.use_selected() and c.items[0].remaining == 30, "Eight-cell capacity rejects expansion without consuming")
	c.begin_continuous_use(); c.tick_continuous_use(-1); c.tick_continuous_use(NAN)
	check(p.real_hp == 200 and c.items[0].remaining == 30, "Invalid elapsed time does not affect item or health")
	c.cancel_use(); c.tick_continuous_use(1)
	check(p.real_hp == 200, "Cancel stops healing immediately")
	var other = load("res://scene/maincharac.tscn").instantiate()
	other.is_locally_controlled = false; root.add_child(other); other.set_physics_process(false)
	check(other.get_health_item_component().items.is_empty(), "Two actors do not share inventory")
	other.free(); p.free()
	print("RESULT: ", failures.size(), " failures"); quit(0 if failures.is_empty() else 1)
