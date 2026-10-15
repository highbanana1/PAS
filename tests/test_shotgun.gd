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
	var w = p.get_weapon_controller(); w.set_process(false)
	var gun = p.get_node("gun")
	check(gun.get("pellet_count") != null, "Gun exposes independent shotgun configuration")
	if gun.get("pellet_count") == null: p.free(); quit(1); return
	if gun.has_method("set_spread_seed"): gun.set_spread_seed(12345)
	check(w.attack(Vector2.RIGHT), "One shot is accepted through the unified weapon API")
	var shots = get_nodes_in_group("bullet")
	check(shots.size() == 5, "One shot creates exactly five pellets")
	var angles: Array = []
	var same_owner := true; var same_origin := true; var correct_damage := true
	for pellet in shots:
		angles.append(rad_to_deg(pellet.rotation))
		same_owner = same_owner and pellet.shooter == p
		same_origin = same_origin and pellet.global_position.is_equal_approx(gun.muzzle.global_position)
		correct_damage = correct_damage and pellet.damage == 2 and pellet.gravity_strength == 35
	angles.sort()
	check(absf(angles[0]) <= 7.501 and absf(angles[4]) <= 7.501, "Every random pellet remains inside the fifteen-degree cone")
	var regular := true
	for index in range(1,4): regular = regular and absf((angles[index+1]-angles[index])-(angles[1]-angles[0])) < 0.0001
	check(not regular and absf(angles[2]) > 0.0001, "Pellets are neither evenly spaced nor forced to the center")
	check(same_owner and same_origin and correct_damage, "All pellets keep shooter, muzzle origin, gentle gravity and per-weapon damage")
	var enemy = load("res://scene/enemy.tscn").instantiate(); root.add_child(enemy); enemy.set_physics_process(false)
	enemy.health_item_drop_chance = 0
	shots[0]._on_area_2d_body_entered(enemy); shots[1]._on_area_2d_body_entered(enemy)
	check(enemy.health == 1 and not enemy.is_queued_for_deletion(), "Two pellet hits leave a basic enemy alive")
	shots[2]._on_area_2d_body_entered(enemy)
	check(enemy.health == 0 and enemy.is_queued_for_deletion(), "Third pellet hit kills the basic enemy")
	clear_shots(); enemy.free()
	gun.get_shot_cycle().tick(gun.shot_interval); w.attack(Vector2.RIGHT); var next_angles: Array = []
	for pellet in get_nodes_in_group("bullet"): next_angles.append(rad_to_deg(pellet.rotation))
	next_angles.sort()
	check(next_angles != angles, "Successive shots do not reuse a fixed spread pattern")
	clear_shots()
	gun.pellet_count = 1; gun.spread_degrees = 15
	gun.get_shot_cycle().tick(gun.shot_interval); w.attack(Vector2.UP); shots = get_nodes_in_group("bullet")
	check(shots.size() == 1 and absf(angle_difference(shots[0].rotation,-PI/2))<0.001, "Single pellet configuration shoots straight without division by zero")
	clear_shots(); gun.pellet_count = 5; gun.spread_degrees = 15
	gun.set_spread_seed(2718); var repeat = gun.generate_pellet_offsets(); gun.set_spread_seed(2718)
	check(repeat == gun.generate_pellet_offsets(), "Explicit seed reproduces a spread for future authoritative commands")
	var central := 0; var samples := 0; var max_angle := 0.0
	for burst in range(1000):
		for offset in gun.generate_pellet_offsets():
			samples += 1
			max_angle = maxf(max_angle,absf(rad_to_deg(offset)))
			if absf(rad_to_deg(offset)) < 3.75: central += 1
	check(float(central)/samples > 0.70 and float(central)/samples < 0.80, "Random spread favors center without fixed pellet positions")
	check(max_angle <= 7.501 and max_angle > 6.5, "Random samples respect full cone bounds without silently narrowing spread")
	var another = load("res://scene/gun.tscn").instantiate()
	gun.set_spread_seed(123); another.set_spread_seed(123)
	var initial = gun.generate_pellet_offsets(); gun.generate_pellet_offsets()
	check(another.generate_pellet_offsets() == initial, "Each weapon owns an independent random stream")
	another.free()
	gun.spread_degrees = 0
	gun.get_shot_cycle().tick(gun.shot_interval); w.attack(Vector2.LEFT); shots = get_nodes_in_group("bullet")
	var straight := true
	for pellet in shots: straight = straight and absf(angle_difference(pellet.rotation,PI))<0.001
	check(shots.size() == 5 and straight, "Zero spread remains five aligned leftward pellets")
	clear_shots(); w.equip_weapon(1)
	check(not gun.attack(Vector2.RIGHT) and get_nodes_in_group("bullet").is_empty(), "Inactive gun cannot emit a shotgun burst")
	var base = load("res://scene/bullet.tscn").instantiate()
	check(base.damage == 1, "Shared bullet default damage stays unchanged for other weapons")
	base.free(); p.free(); print("RESULT: ",failures.size()," failures"); quit(0 if failures.is_empty() else 1)
