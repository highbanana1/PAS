extends SceneTree
var failures: Array[String] = []
func _initialize() -> void: run.call_deferred()
func check(ok: bool, label: String) -> void:
	print(("PASS: " if ok else "FAIL: ") + label)
	if not ok: failures.append(label)
func run() -> void:
	var actor = load("res://scene/maincharac.tscn").instantiate()
	actor.is_locally_controlled = false
	root.add_child(actor)
	check(actor.has_method("get_respawn_component") and actor.has_method("get_carry_component"), "Actor exposes independent lifecycle and carry components")
	if not actor.has_method("get_respawn_component"):
		actor.free(); quit(1); return
	var Life = load("res://scene/script/components/respawn_component.gd")
	var a = Life.new(); var b = Life.new()
	var ta := Timer.new(); var tb := Timer.new()
	root.add_child(ta); root.add_child(tb); root.add_child(a); root.add_child(b)
	a.configure(ta, Vector2(10, 20), 0.1)
	b.configure(tb, Vector2(30, 40), 1.0)
	check(a.die() and a.dead and not b.dead, "Death and timers belong to one component instance")
	var before: float = ta.time_left
	check(not a.die() and ta.time_left <= before, "Repeated death cannot extend a countdown")
	await create_timer(0.2).timeout
	check(not a.dead and a.spawn_position == Vector2(10, 20), "Independent countdown completes without replacing the owner")
	var game = load("res://scene/main.tscn").instantiate()
	root.add_child(game)
	var player = game.get_node("CharacterBody2D")
	player.set_physics_process(false)
	game.get_node("enemy").set_physics_process(false)
	var item = game.get_node("WinningPoint")
	check(player.get_carry_component().try_pick_up(item), "Carry component accepts an explicitly supplied item")
	player.global_position = Vector2(900, -90)
	player.get_carry_component().drop()
	check(not item.is_picked and player.current_winning_point == null and item.global_position == Vector2(900, -90), "Drop clears ownership at the carrier position without gravity")
	var other := Node2D.new()
	root.add_child(other)
	var Carry = load("res://scene/script/components/carry_component.gd")
	var carry = Carry.new()
	other.add_child(carry)
	carry.configure(other)
	check(carry.try_pick_up(item), "Carry behavior works for a differently named plain Node2D actor")
	var receiver = game.get_node("wtable").get_delivery_receiver()
	check(carry.deliver_to(receiver) and item.ref == game.get_node("wtable") and carry.item == null, "Generic delivery transfers item to the configured receiver")
	check(not player.get_carry_component().try_pick_up(item), "Delivered items cannot be reclaimed accidentally")
	var health_updates: Array[int] = []
	actor.health_changed.connect(func(): health_updates.append(1))
	kill_actor(actor)
	health_updates.clear()
	actor.respawn(Vector2.ZERO)
	check(health_updates.size() == 1, "Respawn emits one legacy health update for one health reset")
	game.free(); other.free(); actor.free(); a.free(); b.free(); ta.free(); tb.free()
	print("RESULT: ", failures.size(), " failures")
	quit(0 if failures.is_empty() else 1)

# Death fixtures now deplete one cell per hit, including duplicate-death coverage.
func kill_actor(actor: Node) -> void:
	for index in range(9):
		actor.take_damage(actor.max_hp)
		if actor.is_dead: return
