extends SceneTree
var failures: Array[String] = []
func _initialize() -> void: run.call_deferred()
func check(ok: bool, label: String) -> void:
	print(("PASS: " if ok else "FAIL: ") + label)
	if not ok: failures.append(label)
func run() -> void:
	var p = load("res://scene/maincharac.tscn").instantiate(); p.is_locally_controlled = false
	root.add_child(p); p.set_physics_process(false)
	var gun = p.get_node("gun"); var w = p.get_weapon_controller(); w.set_process(false)
	w.attack(Vector2.UP)
	var flashes = get_nodes_in_group("muzzle_flash")
	check(flashes.size() == 1, "Successful shot emits exactly one muzzle effect")
	if flashes.is_empty(): p.free(); quit(1); return
	var effect = flashes[0]; effect.set_process(false)
	check(effect.global_position.is_equal_approx(gun.muzzle.global_position), "Flash originates at the muzzle")
	check(effect.global_transform.x.normalized().distance_to(Vector2.UP) < 0.001, "Flash and sparks follow fire direction")
	check(effect.get_parent() == root and effect.get_child_count() == 0, "Cosmetic effect has no collision or gameplay children")
	var previous: Vector2 = effect.global_position; p.position += Vector2(150,150)
	check(effect.global_position == previous, "Emitted sparks stay at the shot rather than following the player")
	gun.set_active(false); gun.attack(Vector2.RIGHT)
	check(get_nodes_in_group("muzzle_flash").size() == 1, "Rejected attack cannot emit a flash")
	effect._process(0.5)
	check(effect.is_queued_for_deletion(), "Flash and particles self-clean after their lifetime")
	for bullet in get_nodes_in_group("bullet"): bullet.free()
	p.free(); print("RESULT: ",failures.size()," failures"); quit(0 if failures.is_empty() else 1)
