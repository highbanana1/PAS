extends SceneTree
var failures: Array[String] = []
func _initialize() -> void: run.call_deferred()
func check(ok: bool, label: String) -> void:
	print(("PASS: " if ok else "FAIL: ") + label)
	if not ok: failures.append(label)
func run() -> void:
	var p = load("res://scene/maincharac.tscn").instantiate(); p.is_locally_controlled = false
	root.add_child(p); p.set_physics_process(false)
	var w = p.get_weapon_controller(); w.set_process(false); var gun = p.get_node("gun")
	check(gun.has_method("get_shot_cycle"), "Shotgun exposes its independent pump cycle")
	if not gun.has_method("get_shot_cycle"): p.free(); quit(1); return
	var cycle = gun.get_shot_cycle(); cycle.set_process(false)
	var rest: Vector2 = cycle.get_node("Pump").position
	check(is_equal_approx(gun.shot_interval,0.65), "Default shot interval is 0.65 seconds")
	check(w.attack(Vector2.RIGHT) and gun.is_busy(), "Accepted shot starts the pump interval")
	check(not w.attack(Vector2.RIGHT) and get_nodes_in_group("bullet").size() == 5 and get_nodes_in_group("muzzle_flash").size() == 1, "Fast repeat click produces neither pellets nor flash")
	var origin: Vector2 = gun.muzzle.global_position
	cycle.tick(0.27)
	check(cycle.get_node("Pump").position.x < rest.x and gun.muzzle.global_position == origin, "Foreend moves backward while gameplay muzzle stays fixed")
	w.equip_weapon(1)
	check(cycle.get_node("Pump").position == rest and cycle.remaining > 0, "Switching weapons restores pose but retains gun cooldown")
	cycle.tick(0.03)
	check(cycle.get_node("Pump").position == rest and cycle.position == Vector2.ZERO, "Hidden cycle keeps its visual pose at rest while its clock advances")
	check(w.attack(Vector2.RIGHT), "Sword attacks independently during shotgun cooldown")
	w.equip_weapon(0)
	check(not w.attack(Vector2.RIGHT), "Switching back cannot bypass the gun interval")
	var remaining: float = cycle.remaining
	cycle.tick(NAN); cycle.tick(-1)
	check(cycle.remaining == remaining, "Invalid deltas cannot change cycle timing")
	w.equip_weapon(1); cycle.tick(remaining + 0.001); w.equip_weapon(0)
	check(not gun.is_busy() and cycle.position == Vector2.ZERO and cycle.rotation == 0 and cycle.get_node("Pump").position == rest, "Hidden gun finishes its interval and restores exact pose")
	check(w.attack(Vector2.LEFT), "Gun fires again after the animation interval")
	var other = load("res://scene/gun.tscn").instantiate(); root.add_child(other)
	check(not other.is_busy(), "Other shotgun instances keep independent cycle state")
	other.free()
	w.reset_after_respawn()
	check(not gun.is_busy() and cycle.get_node("Pump").position == rest and w.attack(Vector2.UP), "Respawn reset clears pump and permits a fresh shot")
	cycle.set_process(true); gun.set_active(false)
	check(cycle.is_processing() and not gun.is_processing(), "Remote and unequipped guns advance the cycle without local input processing")
	await create_timer(gun.shot_interval + 0.05).timeout
	check(not gun.is_busy() and cycle.get_node("Pump").position == rest, "Hidden remote shotgun finishes its cooldown through real frame processing")
	for bullet in get_nodes_in_group("bullet"): bullet.free()
	for effect in get_nodes_in_group("muzzle_flash"): effect.free()
	p.free(); print("RESULT: ",failures.size()," failures"); quit(0 if failures.is_empty() else 1)
