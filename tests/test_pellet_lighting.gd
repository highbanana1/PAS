extends SceneTree
var failures: Array[String] = []
func _initialize() -> void: run.call_deferred()
func check(ok: bool, label: String) -> void:
	print(("PASS: " if ok else "FAIL: ") + label)
	if not ok: failures.append(label)
func run() -> void:
	var scene = load("res://scene/bullet.tscn"); var a = scene.instantiate(); var b = scene.instantiate()
	check(a.has_method("set_fire_light_origin"), "Pellet has an independent directional fire-light interface")
	if not a.has_method("set_fire_light_origin"): a.free(); b.free(); quit(1); return
	a.position = Vector2(100,100); b.position = Vector2(-100,100); b.rotation = PI
	root.add_child(a); root.add_child(b); a.set_process(false); b.set_process(false)
	a.set_fire_light_origin(Vector2(0,100)); b.set_fire_light_origin(Vector2(0,100))
	var am = a.get_node("Sprite2D").material; var bm = b.get_node("Sprite2D").material
	check(am != bm, "Each pellet owns its lighting material so players cannot change one another's highlights")
	var al: Vector2 = am.get_shader_parameter("light_direction"); var bl: Vector2 = bm.get_shader_parameter("light_direction")
	check(al.is_equal_approx(Vector2.LEFT) and bl.distance_to(Vector2.LEFT) < 0.001, "Light points back toward the muzzle for both left and right fire")
	a.set_fire_light_origin(Vector2(100,0)); al = am.get_shader_parameter("light_direction")
	check(al.is_equal_approx(Vector2.UP) and bm.get_shader_parameter("light_direction").distance_to(Vector2.LEFT)<0.001, "Directional highlight can change without affecting another pellet")
	a._process(0.25); al = am.get_shader_parameter("light_direction")
	var toward: Vector2 = (Vector2(100,0)-a.global_position).normalized()
	check(a.global_transform.basis_xform(al).normalized().distance_to(toward)<0.001, "Lighting tracks the fixed firing origin during curved flight")
	var before = am.get_shader_parameter("light_direction"); a.set_fire_light_origin(Vector2(NAN,0))
	check(am.get_shader_parameter("light_direction") == before, "Invalid light origins cannot poison the shader")
	a.free(); b.free(); print("RESULT: ",failures.size()," failures"); quit(0 if failures.is_empty() else 1)
