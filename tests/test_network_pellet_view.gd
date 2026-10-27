extends SceneTree

var failures: Array[String] = []

func _initialize() -> void:
	_run.call_deferred()

func check(ok: bool, label: String) -> void:
	print(('PASS: ' if ok else 'FAIL: ') + label)
	if not ok: failures.append(label)

func _run() -> void:
	var script = load('res://scene/script/network/pellet_view.gd')
	check(script != null, 'Network pellet presentation is loadable')
	if script != null:
		var view = script.new()
		root.add_child(view)
		var pellets: Array = []
		for i in range(5):
			pellets.append({'shot_id': 1, 'pellet_id': i, 'position': Vector2(20 + i, 30), 'velocity': Vector2.RIGHT * 700, 'origin': Vector2.ZERO})
		view.apply_projectiles(pellets)
		check(view.get_child_count() == 5, 'Five authority records create five visible pellets')
		var safe := true
		for child in view.get_children():
			safe = safe and child is Sprite2D and child.get_child_count() == 0 and child.get_script() == null
		check(safe, 'Presentation contains no collision or damage scripts')
		view.apply_projectiles(pellets)
		check(view.get_child_count() == 5, 'Repeated checkpoint does not duplicate pellets')
		pellets[0]['position'] = Vector2(4000, 3000)
		view.apply_projectiles(pellets)
		check(view.get_child(0).global_position == Vector2(4000, 3000), 'Offscreen authority position stays visible in state')
		view.apply_projectiles([])
		check(view.get_child_count() == 0, 'Authority removal clears every visual immediately')
		view.free()
	print('RESULT: ', failures.size(), ' failures')
	quit(0 if failures.is_empty() else 1)
