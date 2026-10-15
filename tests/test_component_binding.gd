extends SceneTree
var failures: Array[String] = []
func _initialize() -> void: run.call_deferred()
func check(ok: bool, label: String) -> void:
	print(("PASS: " if ok else "FAIL: ") + label)
	if not ok: failures.append(label)
func run() -> void:
	var game = load("res://scene/main.tscn").instantiate()
	root.add_child(game); current_scene = game
	var a = game.get_node("CharacterBody2D")
	a.set_physics_process(false); a.get_weapon_controller().set_process(false)
	game.get_node("enemy").set_physics_process(false)
	var hud = game.get_node("CombatHUD")
	check(hud.has_method("bind_actor") and hud.has_method("unbind_actor"), "Combat UI supports explicit bind and unbind")
	if not hud.has_method("bind_actor"):
		game.free(); quit(1); return
	var b = load("res://scene/maincharac.tscn").instantiate()
	b.position = Vector2(2000,-300); game.add_child(b)
	b.set_physics_process(false); b.get_weapon_controller().set_process(false)
	b.real_hp = 50; b.get_weapon_controller().guard_value = 30
	hud.bind_actor(a); hud.bind_actor(b); hud.bind_actor(b)
	check(hud.get_node("%GuardBar").value == 30, "Repeated rebinding initializes the new actor immediately")
	a.get_weapon_controller().guard_changed.emit(10,100)
	check(hud.get_node("%GuardBar").value == 30, "Old actor signals cannot modify the new actor HUD")
	b.get_weapon_controller().guard_changed.emit(45,100)
	check(hud.get_node("%GuardBar").value == 45, "New actor changes update the HUD")
	var hp = game.get_node("UILayer")
	hp.bind_actor(b)
	check(hp.bar1.value == 30 and hp.bar2.value == 20 and hp.bar3.value == 0, "Health UI immediately binds to component state")
	a.take_damage(10)
	check(hp.bar2.value == 20, "Health UI disconnects its original actor")
	var screen = game.get_node("DeathScreen")
	screen.bind_actor(b)
	kill_actor(b)
	check(screen.visible and screen.get_node("%Countdown").text == "5", "Death UI subscribes to the bound actor lifecycle component")
	screen.bind_actor(a)
	check(not screen.visible, "Rebinding death UI clears the previous death state")
	b.free()
	check(not hud.visible and not hp.visible, "Deleting a bound actor safely unbinds its views")
	a.is_locally_controlled = false
	hud.bind_actor(a); hp.bind_actor(a); screen.bind_actor(a)
	check(not hud.visible and not hp.visible and not screen.visible, "Remote actors do not claim local views")
	hud.bind_actor(null); hp.bind_actor(null); screen.bind_actor(null)
	check(not hud.visible and not hp.visible and not screen.visible, "Null binding safely hides all views")
	game.free()
	print("RESULT: ", failures.size(), " failures")
	quit(0 if failures.is_empty() else 1)

# Death fixtures now deplete one cell per hit, including duplicate-death coverage.
func kill_actor(actor: Node) -> void:
	for index in range(9):
		actor.take_damage(actor.max_hp)
		if actor.is_dead: return
