extends SceneTree
var failures: Array[String] = []
func _initialize() -> void: run.call_deferred()
func check(ok: bool, label: String) -> void:
	print(("PASS: " if ok else "FAIL: ") + label)
	if not ok: failures.append(label)
func clear_shots() -> void:
	for bullet in get_nodes_in_group("bullet"): bullet.free()
func run() -> void:
	var p = load("res://scene/maincharac.tscn").instantiate(); p.is_locally_controlled = false
	root.add_child(p); p.set_physics_process(false)
	var gun = p.get_node("gun"); var w = p.get_weapon_controller(); w.set_process(false)
	check(gun.get("pellet_speed_variation") != null, "Shotgun exposes gentle cloud depth variation")
	if gun.get("pellet_speed_variation") == null: p.free(); quit(1); return
	gun.set_spread_seed(12345); w.attack(Vector2.RIGHT)
	var shots = get_nodes_in_group("bullet"); var distances: Array = []; var bounded := true; var lit := true
	for bullet in shots:
		bullet.set_process(false); var origin: Vector2 = bullet.position; bullet._process(0.25)
		distances.append(bullet.position.x - origin.x)
		bounded = bounded and bullet.speed_multiplier >= 0.92 and bullet.speed_multiplier <= 1.08
		var sprite = bullet.get_node("Sprite2D")
		lit = lit and sprite.material is ShaderMaterial and sprite.texture.resource_path == "res://asset/pic/bullet_standred.png"
	distances.sort()
	check(shots.size() == 5 and distances.back() - distances.front() > 5, "Five pellets form a cloud with front-to-back depth rather than a flat wavefront")
	check(bounded, "Speed variation stays within eight percent")
	check(lit, "Every pellet reuses asset texture with pixel warm rim material")
	clear_shots(); gun.get_shot_cycle().tick(gun.shot_interval); gun.pellet_speed_variation = 0; w.attack(Vector2.RIGHT)
	check(get_nodes_in_group("bullet").size() == 5 and get_nodes_in_group("bullet").all(func(b): return b.speed_multiplier == 1), "Zero cloud depth retains identical pellet speeds")
	clear_shots(); var normal = load("res://scene/bullet.tscn").instantiate()
	check(normal.speed_multiplier == 1 and normal.damage == 1 and normal.gravity_strength == 35, "Other projectile defaults are unchanged")
	normal.free(); p.free(); print("RESULT: ",failures.size()," failures"); quit(0 if failures.is_empty() else 1)
