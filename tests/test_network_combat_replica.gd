extends SceneTree
const Replica = preload("res://scene/script/network/combat_replica.gd")
var failures: Array[String] = []
func _initialize() -> void: run.call_deferred()
func check(ok: bool, label: String) -> void:
	print(("PASS: " if ok else "FAIL: ") + label)
	if not ok: failures.append(label)
func packet(tick: int, revision: int, alive: bool) -> Dictionary:
	return {"match_epoch":303,"server_tick":tick,"players":{"target":{"health":31 if alive else 0,"dead":not alive}},"combat":{"server_tick":tick,"revision":revision,"projectiles":[{"shot_id":1,"pellet_id":0,"position":Vector2.ZERO}] if alive else [],"events":[{"event_id":revision,"type":"shot_spawned" if alive else "pellet_removed","shot_id":1,"pellet_id":0}]}}
func run() -> void:
	var r = Replica.new(); r.configure(303)
	var spawn := packet(10,1,true)
	var remove := packet(13,2,false)
	check(r.apply_packet(spawn), "Replica accepts authoritative shot checkpoint")
	check(not r.apply_packet(spawn), "Duplicate checkpoint is idempotently ignored")
	check(r.get_state().projectiles.size() == 1, "Duplicate spawn does not create more pellets")
	check(r.apply_packet(remove), "New removal checkpoint applies")
	check(not r.apply_packet(spawn), "Delayed spawn cannot resurrect removed pellet")
	check(r.get_state().projectiles.is_empty(), "Removed pellet stays absent after reordering")
	check(r.get_player("target").health == 0 and r.get_player("target").dead, "Old checkpoint cannot restore dead player health")
	var stale_revision := packet(14,1,true)
	check(not r.apply_packet(stale_revision), "Later arrival with regressed combat revision is rejected")
	var old_tick := packet(9,3,true)
	check(not r.apply_packet(old_tick), "Older server tick is rejected even with higher revision")
	var wrong_epoch := packet(15,4,true); wrong_epoch.match_epoch = 999
	check(not r.apply_packet(wrong_epoch), "Other match epoch cannot alter combat")
	var corrupt := packet(15,4,true); corrupt.combat.projectiles = "bad"
	check(not r.apply_packet(corrupt), "Malformed projectile list rejected")
	var copy: Dictionary = r.get_state(); copy.projectiles.append({"shot_id":99})
	check(r.get_state().projectiles.is_empty(), "Public combat state cannot mutate authority replica")
	r.clear()
	check(r.get_state().is_empty(), "Session close clears projectile presentation state")
	print("RESULT: ",failures.size()," failures")
	quit(0 if failures.is_empty() else 1)
