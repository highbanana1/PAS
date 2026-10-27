extends SceneTree
const Session = preload("res://scene/script/network/network_session.gd")
const Bridge = preload("res://scene/script/network/match_network_bridge.gd")
const Actor = preload("res://tests/fixtures/network_combat_actor.gd")
var session
var bridge
var folder: String
var role: String
var host_id: String
var target
func _initialize() -> void: run.call_deferred()
func write(name: String, data: Dictionary) -> void:
	var f := FileAccess.open(folder.path_join(name + ".tmp"), FileAccess.WRITE)
	f.store_string(JSON.stringify(data)); f.close()
	DirAccess.rename_absolute(folder.path_join(name + ".tmp"), folder.path_join(name))
func read(name: String) -> Dictionary:
	var path := folder.path_join(name)
	if not FileAccess.file_exists(path): return {}
	var v: Variant = JSON.parse_string(FileAccess.get_file_as_string(path))
	return v if v is Dictionary else {}
func make_actor(pos: Vector2):
	var a = Actor.new(); a.position = pos; root.add_child(a); return a
func run() -> void:
	var args := OS.get_cmdline_user_args()
	role = args[0]; folder = args[1]
	session = Session.new(); session.name = "NetworkSession"; root.add_child(session)
	bridge = Bridge.new(); bridge.name = "MatchNetworkBridge"; root.add_child(bridge)
	if role == "host":
		if session.host(0, {"match_epoch":303303}) != OK: quit(1); return
		bridge.configure(session)
		host_id = session.get_local_identity().player_id
		target = make_actor(Vector2(48,0))
		target.health_component.set_current(31)
		bridge.bind_actor(StringName(host_id), target, true)
		session.player_joined.connect(func(_peer, pid): bridge.bind_actor(StringName(pid), make_actor(Vector2.ZERO)))
		write("ready.json", {"port":session.get_port(),"host_id":host_id})
		await run_host()
	else:
		var ready := read("ready.json"); host_id = ready.host_id
		session.join("127.0.0.1", int(ready.port)); bridge.configure(session)
		await run_client()
func run_host() -> void:
	var deadline := Time.get_ticks_msec() + 18000
	var phase := 0
	while Time.get_ticks_msec() < deadline:
		await process_frame
		if phase == 0 and target.real_hp == 22:
			write("host_hit.json", {"health":target.real_hp,"combat":bridge.get_combat_state()})
			phase = 1
		if phase == 1 and not read("client_hit.json").is_empty():
			target.health_component.set_current(5)
			write("second.json", {"ready":true}); phase = 2
		if phase == 2 and target.is_dead and bridge.get_combat_state().projectiles.is_empty():
			write("host_final.json", {"health":target.real_hp,"dead":target.is_dead,"combat":bridge.get_combat_state()})
			phase = 3
		if phase == 3 and not read("client_final.json").is_empty():
			session.stop(); quit(0); return
	write("host_error.json", {"error":"timeout","phase":phase,"health":target.real_hp})
	session.stop(); quit(1)
func run_client() -> void:
	var deadline := Time.get_ticks_msec() + 16000
	var phase := 0
	var fire_time := 0
	var old_baseline: Dictionary = {}
	var seen: Dictionary = {}
	while Time.get_ticks_msec() < deadline:
		await process_frame
		if not bridge.has_baseline(): continue
		var combat: Dictionary = bridge.get_combat_state()
		for event in combat.get("events", []):
			if event.get("type") == "shot_spawned": seen[event.shot_id] = event
		if phase == 0 and bridge.get_replica_states().size() >= 2:
			old_baseline = bridge.get_last_baseline()
			bridge.submit_command({"type":"fire","direction":Vector2.RIGHT,"player_id":host_id,"damage":9000,"origin":Vector2(9000,0),"pellet_count":50})
			fire_time = Time.get_ticks_msec(); phase = 1
		var state: Dictionary = bridge.get_replica_state(StringName(host_id))
		if phase == 1 and float(state.get("health",-1)) == 22:
			var before: Dictionary = bridge.get_combat_state().duplicate(true)
			var duplicate: Dictionary = bridge.apply_baseline(old_baseline)
			write("client_hit.json", {"health":state.health,"combat":combat,"shots":seen.values(),"stale_rejected":not duplicate.get("applied",true),"no_rollback":before == bridge.get_combat_state()})
			phase = 2
		if phase == 2 and not read("second.json").is_empty() and Time.get_ticks_msec() - fire_time > 900:
			bridge.submit_fire(Vector2.RIGHT); phase = 3
		if phase == 3 and state.get("dead",false) and combat.get("projectiles",[1]).is_empty():
			write("client_final.json", {"health":state.health,"dead":state.dead,"combat":combat,"shots":seen.values()})
			await create_timer(0.15).timeout
			session.stop(); quit(0); return
	write("client_error.json", {"error":"timeout","phase":phase,"states":bridge.get_replica_states()})
	session.stop(); quit(1)


