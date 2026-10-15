extends SceneTree
var failures: Array[String] = []
func _initialize() -> void: run.call_deferred()
func check(ok: bool, label: String) -> void:
	print(("PASS: " if ok else "FAIL: ") + label)
	if not ok: failures.append(label)
func run() -> void:
	var scene = load("res://scene/bullet.tscn")
	var a = scene.instantiate(); var b = scene.instantiate(); var left = scene.instantiate(); var up = scene.instantiate()
	check(a.get("gravity_strength") != null, "Projectile exposes gentle gravity in Inspector")
	if a.get("gravity_strength") == null:
		a.free(); b.free(); left.free(); up.free(); quit(1); return
	check(a.get_node("Sprite2D").scale.is_equal_approx(Vector2.ONE * 0.004277778), "Pellet diameter is half the previous size")
	a._process(0.5)
	check(a.position.is_equal_approx(Vector2(350,4.375)), "Half-second flight keeps speed and drops only 4.375 pixels")
	a._process(0.5); b._process(1)
	check(a.position.is_equal_approx(Vector2(700,17.5)) and a.position.is_equal_approx(b.position), "Gravity is independent of time-step size")
	left.rotation = PI; left._process(1)
	check(left.position.distance_to(Vector2(-700,17.5)) < 0.001, "Leftward shots still fall downward")
	up.rotation = -PI/2; up._process(1)
	check(up.position.distance_to(Vector2(0,-682.5)) < 0.001, "Upward shots are gently slowed by world-down gravity")
	var straight = scene.instantiate(); straight.gravity_strength = 0; straight._process(1)
	check(straight.position == Vector2(700,0), "Zero Inspector gravity restores a straight shot")
	a.free(); b.free(); left.free(); up.free(); straight.free()
	print("RESULT: ",failures.size()," failures"); quit(0 if failures.is_empty() else 1)
