extends SceneTree

var failures: Array[String] = []
func _initialize() -> void:
	run.call_deferred()
func check(ok: bool, label: String) -> void:
	print(("PASS: " if ok else "FAIL: ") + label)
	if not ok: failures.append(label)
func run() -> void:
	var actor = load("res://scene/maincharac.tscn").instantiate()
	actor.name = "ArbitraryActor"
	actor.is_locally_controlled = false
	root.add_child(actor)
	actor.set_physics_process(false)
	check(actor.has_method("get_combat_receiver"), "Actor exposes the reusable combat receiver")
	if not actor.has_method("get_combat_receiver"):
		actor.free()
		quit(1)
		return
	var Health = load("res://scene/script/components/health_component.gd")
	var Context = load("res://scene/script/combat/attack_context.gd")
	var Receiver = load("res://scene/script/combat/combat_receiver.gd")
	var a = Health.new()
	var b = Health.new()
	root.add_child(a)
	root.add_child(b)
	a.configure(90)
	b.configure(90)
	var receiver = Receiver.new()
	root.add_child(receiver)
	receiver.configure(actor, a)
	check(receiver.receive_attack(Context.new(10, Vector2.ZERO)) == Context.Result.DAMAGED and a.current == 80 and b.current == 90, "Independent health components receive typed damage results")
	check(a.apply_damage(-10) == 0 and a.apply_damage(NAN) == 0 and a.current == 80, "Invalid damage cannot heal or poison health")
	check(a.heal(100) == 10 and a.current == 90, "Healing clamps to maximum")
	var deaths: Array[int] = []
	a.depleted.connect(func(): deaths.append(1))
	check(receiver.receive_attack(Context.new(100, Vector2.ZERO)) == Context.Result.KILLED and a.current == 0, "Lethal attack reports KILLED")
	check(receiver.receive_attack(Context.new(10, Vector2.ZERO)) == Context.Result.IGNORED and deaths.size() == 1, "Dead targets ignore repeated damage and die only once")
	a.restore_full()
	check(a.current == 90, "Health can reset without replacing its owner")
	var enemy = load("res://scene/enemy.tscn").instantiate()
	root.add_child(enemy)
	enemy.set_physics_process(false)
	check(enemy.has_method("get_combat_receiver"), "Enemy shares the same combat entry point")
	check(Receiver.deliver(enemy, Context.new(1, Vector2.ZERO)) == Context.Result.DAMAGED and enemy.health == 4 and not enemy.get_hited, "Enemy takes damage without a pre-set hit flag")
	actor.take_damage(10)
	check(actor.real_hp == 140 and actor.get_combat_receiver().health.current == 140, "Legacy player damage proxies the single health source")
	receiver.free(); a.free(); b.free(); enemy.free(); actor.free()
	print("RESULT: ", failures.size(), " failures")
	quit(0 if failures.is_empty() else 1)
