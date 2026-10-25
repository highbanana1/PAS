class_name MatchNetworkBridge
extends Node

## Small bridge between NetworkSession's validated command transport and
## MatchAuthority's gameplay seam. On the host it drains trusted command
## records, submits them to the authority, steps at 60 Hz and broadcasts
## snapshot batches at 20 Hz. On a client it submits local intents through the
## same session envelope path and applies authoritative batches to an
## observable replica. Visual-only prediction and interpolation live in
## ClientMotionView; gameplay state is never predicted or decided here.

signal replicas_updated(batch: Dictionary)
signal snapshot_rejected(result: Dictionary)
signal baseline_received(baseline: Dictionary)
signal baseline_applied(baseline: Dictionary)
signal baseline_rejected(result: Dictionary)
signal baseline_sent(peer_id: int, baseline: Dictionary)
signal session_closed()
signal combat_state_changed(active: bool)

const MatchAuthorityScript = preload("res://scene/script/network/match_authority.gd")
const SnapshotReplicaScript = preload("res://scene/script/network/snapshot_replica.gd")
const ClientMotionViewScript = preload("res://scene/script/network/client_motion_view.gd")
const NetworkPelletViewScript = preload("res://scene/script/network/pellet_view.gd")

const AUTHORITY_HZ: int = 60
const SNAPSHOT_HZ: int = 20
const FIXED_STEP: float = 1.0 / 60.0
const SNAPSHOT_INTERVAL: float = 1.0 / 20.0
const MAX_CATCHUP_STEPS: int = 8
const EPSILON: float = 0.000001

var combat_replica = preload("res://scene/script/network/combat_replica.gd").new()
var _sent_combat_revision: int = 0
var _pending_combat_packet: Dictionary = {}
signal combat_updated(state: Dictionary)

var session
var authority
var replica
var client_view
var pellet_view

var _configured: bool = false
var _host_authority: bool = false
var _local_player_id: StringName = &""
var _actors: Dictionary = {}
var _step_accumulator: float = 0.0
var _snapshot_accumulator: float = 0.0
var _authority_steps: int = 0
var _physics_frames: int = 0
var _snapshots_sent: int = 0
var _last_snapshot_tick: int = -1
var _last_snapshot_batch: Dictionary = {}
var _submitted_commands: int = 0
var _consumed_commands: int = 0
var _authority_rejected_commands: int = 0
var _command_counts: Dictionary = {}
var _last_applied_batch: Dictionary = {}
var _last_applied_tick: int = -1
var _last_rejection: Dictionary = {}
var _pending_baseline_peers: Dictionary = {}
var _baseline_sent_count: int = 0
var _last_baseline_sent: Dictionary = {}
var _baseline_received_count: int = 0
var _baseline_applied_count: int = 0
var _last_baseline: Dictionary = {}
var _last_baseline_tick: int = -1
var _baseline_rejections: Dictionary = {}
var _session_closed: bool = false
var _combat_active: bool = false

func configure(session_node: Node, authority_instance = null) -> bool:
	if _configured or not is_instance_valid(session_node):
		return false
	if not session_node.has_method("is_host") or not session_node.has_method("is_active"):
		return false
	if not session_node.is_active():
		return false
	session = session_node
	combat_replica.configure(session.get_match_epoch())
	if session.has_signal("combat_state_received"):
		session.combat_state_received.connect(_on_combat_packet)
	_host_authority = bool(session.is_host())
	replica = SnapshotReplicaScript.new()
	if _host_authority:
		if authority_instance != null:
			authority = authority_instance
		else:
			authority = MatchAuthorityScript.new()
		if authority == null:
			return false
		replica.configure(session.get_match_epoch())
		_set_local_identity()
		if not session.player_joined.is_connected(_on_player_joined):
			session.player_joined.connect(_on_player_joined)
		if not session.player_left.is_connected(_on_player_left):
			session.player_left.connect(_on_player_left)
	else:
		if not session.snapshot_batch_received.is_connected(_on_snapshot_batch_received):
			session.snapshot_batch_received.connect(_on_snapshot_batch_received)
		if not session.identity_assigned.is_connected(_on_identity_assigned):
			session.identity_assigned.connect(_on_identity_assigned)
		if not session.baseline_received.is_connected(_on_baseline_received):
			session.baseline_received.connect(_on_baseline_received)
		if not session.baseline_rejected.is_connected(_on_session_baseline_rejected):
			session.baseline_rejected.connect(_on_session_baseline_rejected)
		client_view = ClientMotionViewScript.new()
		client_view.configure(session.get_match_epoch())
		_set_local_identity()
	if not session.session_closed.is_connected(_on_session_closed):
		session.session_closed.connect(_on_session_closed)
	_configured = true
	pellet_view = NetworkPelletViewScript.new()
	pellet_view.name = "NetworkPelletView"
	add_child(pellet_view)
	pellet_view.configure(self)
	if _host_authority:
		_combat_active = true
	elif session.has_baseline():
		_on_baseline_received(session.get_baseline())
	return true

func is_host_authority() -> bool:
	return _host_authority

func get_authority():
	return authority

func get_pellet_view():
	return pellet_view

func get_local_player_id() -> StringName:
	return _local_player_id

func is_combat_active() -> bool:
	return _combat_active and not _session_closed

func is_session_closed() -> bool:
	return _session_closed

func can_submit_command() -> bool:
	if not _configured or session == null or _session_closed:
		return false
	if not session.is_active():
		return false
	if _host_authority:
		return true
	return _combat_active

func has_baseline() -> bool:
	if replica == null:
		return false
	return replica.has_baseline()

func get_last_baseline() -> Dictionary:
	if _last_baseline.is_empty():
		return {}
	return _last_baseline.duplicate(true)

func get_last_baseline_tick() -> int:
	return _last_baseline_tick

func get_baseline_received_count() -> int:
	return _baseline_received_count

func get_baseline_applied_count() -> int:
	return _baseline_applied_count

func get_baseline_sent_count() -> int:
	return _baseline_sent_count

func get_last_baseline_sent() -> Dictionary:
	if _last_baseline_sent.is_empty():
		return {}
	return _last_baseline_sent.duplicate(true)

func get_baseline_rejected_count(reason: String) -> int:
	return int(_baseline_rejections.get(reason, 0))

## Both host-local and client-local intents use this single entrance. For the
## host, NetworkSession immediately validates the envelope into its command
## queue; for a client, the same envelope goes to the server. Neither path
## bypasses MatchAuthority.
func submit_command(command: Dictionary) -> int:
	if not can_submit_command() or command.is_empty():
		return -1
	var sequence := int(session.send_command(command))
	if sequence > 0:
		_submitted_commands += 1
		if not _host_authority and client_view != null:
			client_view.record_local_input(sequence, command)
	return sequence

func submit_move(direction: Vector2) -> int:
	return submit_command({"type": "move", "direction": direction})

func submit_jump() -> int:
	return submit_command({"type": "jump"})

func submit_dash(direction: Vector2) -> int:
	return submit_command({"type": "dash", "direction": direction})

func bind_actor(player_id: StringName, actor: Node, local: bool = false) -> bool:
	if not _configured or player_id == &"" or not is_instance_valid(actor):
		return false
	var key := String(player_id)
	if _actors.has(key):
		return _actors[key] == actor
	if _host_authority:
		if authority == null or not authority.register_player(player_id, actor):
			return false
	elif actor.has_method("set_authority_controlled"):
		actor.set_authority_controlled(true)
	_actors[key] = actor
	if local:
		_local_player_id = player_id
		if not _host_authority and client_view != null:
			client_view.set_local_player(player_id)
			_configure_prediction_speed(actor)
	if not _host_authority:
		_apply_replica_state(key)
	return true

func get_replica_state(player_id: StringName) -> Dictionary:
	if replica == null:
		return {}
	return replica.get_state(player_id)

func get_replica_states() -> Dictionary:
	if replica == null:
		return {}
	return replica.get_states()

func get_applied_snapshot_count() -> int:
	if replica == null:
		return 0
	return replica.get_applied_batch_count()

func get_rejected_snapshot_count(reason: String) -> int:
	if replica == null:
		return 0
	return replica.get_rejected_count(reason)

## Client presentation diagnostics. These read the visual prediction /
## interpolation layer only; the authoritative replica remains untouched.
func get_client_prediction() -> Dictionary:
	if _host_authority or client_view == null:
		return {}
	return client_view.get_local_prediction()

func get_render_state(player_id: StringName) -> Dictionary:
	if _host_authority or client_view == null:
		return {}
	return client_view.get_render_state(player_id)

func get_render_states() -> Dictionary:
	if _host_authority or client_view == null:
		return {}
	return client_view.get_render_states()

func get_render_position(player_id: StringName) -> Vector2:
	if _host_authority or client_view == null:
		return Vector2.ZERO
	return client_view.get_render_position(player_id)

func get_pending_input_count() -> int:
	if _host_authority or client_view == null:
		return 0
	return client_view.get_pending_input_count()

func get_remote_sample_count(player_id: StringName) -> int:
	if _host_authority or client_view == null:
		return 0
	return client_view.get_remote_sample_count(player_id)

func get_remote_interpolated_frame_count(player_id: StringName) -> int:
	if _host_authority or client_view == null:
		return 0
	return client_view.get_remote_interpolated_frame_count(player_id)

func get_remote_snap_event_count(player_id: StringName) -> int:
	if _host_authority or client_view == null:
		return 0
	return client_view.get_remote_snap_event_count(player_id)

func get_remote_fallback_reason(player_id: StringName) -> String:
	if _host_authority or client_view == null:
		return ""
	return client_view.get_remote_fallback_reason(player_id)

func get_remote_render_tick() -> float:
	if _host_authority or client_view == null:
		return 0.0
	return client_view.get_remote_render_tick()

## Presentation-only test/probe seam. It shifts the local predicted render
## position and never forwards anything to NetworkSession or MatchAuthority.
func inject_prediction_error(offset: Vector2) -> bool:
	if _host_authority or client_view == null or _session_closed:
		return false
	return client_view.inject_prediction_error(offset)

func get_last_snapshot_tick() -> int:
	if _host_authority:
		return _last_snapshot_tick
	return _last_applied_tick

func get_last_applied_batch() -> Dictionary:
	return _last_applied_batch.duplicate(true)

func get_last_snapshot_batch() -> Dictionary:
	return _last_snapshot_batch.duplicate(true)

func get_last_rejection() -> Dictionary:
	return _last_rejection.duplicate(true)

func get_command_counts() -> Dictionary:
	return _command_counts.duplicate(true)

func get_submitted_command_count() -> int:
	return _submitted_commands

func get_consumed_command_count() -> int:
	return _consumed_commands

func get_authority_rejected_command_count() -> int:
	return _authority_rejected_commands

func get_authority_step_count() -> int:
	return _authority_steps

func get_physics_frame_count() -> int:
	return _physics_frames

func get_snapshot_send_count() -> int:
	return _snapshots_sent

## Client reception path for the reliable full baseline. The replica owns
## idempotent duplicate/older-baseline rejection; this bridge records transport
## observations and exposes the applied tick to the session.
func apply_baseline(baseline: Dictionary) -> Dictionary:
	var tick := int(baseline.get("baseline_tick", baseline.get("server_tick", -1)))
	if not _configured or _host_authority or replica == null:
		return {"applied": false, "reason": "not_client", "tick": tick, "player_count": 0}
	_baseline_received_count += 1
	baseline_received.emit(baseline.duplicate(true))
	if _session_closed or session == null or not session.is_active():
		return _record_baseline_rejection("not_active", tick)
	var result: Dictionary = replica.apply_baseline(baseline)
	if not bool(result.get("applied", false)):
		return _record_baseline_rejection(String(result.get("reason", "invalid_batch")), tick)
	combat_replica.apply_packet(baseline)
	_last_baseline = baseline.duplicate(true)
	_last_baseline_tick = int(result.get("tick", tick))
	_baseline_applied_count += 1
	if session.has_method("mark_baseline_applied"):
		session.mark_baseline_applied(baseline)
	if client_view != null:
		client_view.apply_baseline(baseline)
	if not _combat_active:
		_combat_active = true
		combat_state_changed.emit(true)
	_apply_all_replicas()
	if not _pending_combat_packet.is_empty():
		_on_combat_packet(_pending_combat_packet)
		_pending_combat_packet = {}
	baseline_applied.emit(baseline.duplicate(true))
	replicas_updated.emit(baseline.duplicate(true))
	return result

## Client reception path. Public so a test or fixture can feed the same replica
## used by the transport RPC. Returns the SnapshotReplica result dictionary.
func apply_snapshot_batch(batch: Dictionary) -> Dictionary:
	var tick := int(batch.get("server_tick", -1))
	if not _configured or _host_authority or replica == null:
		return {"applied": false, "reason": "not_client", "tick": tick, "player_count": 0}
	if _session_closed or session == null or not session.is_active():
		var closed := {"applied": false, "reason": "not_active", "tick": tick, "player_count": 0}
		_last_rejection = closed.duplicate(true)
		snapshot_rejected.emit(closed.duplicate(true))
		return closed
	var result: Dictionary = replica.apply_batch(batch)
	if not bool(result.get("applied", false)):
		_last_rejection = result.duplicate(true)
		snapshot_rejected.emit(result.duplicate(true))
		return result
	combat_replica.apply_packet(batch)
	_last_applied_batch = batch.duplicate(true)
	_last_applied_tick = int(result.get("tick", -1))
	if client_view != null:
		client_view.apply_snapshot(batch)
	_apply_all_replicas()
	replicas_updated.emit(batch.duplicate(true))
	return result

func _record_baseline_rejection(reason: String, tick: int) -> Dictionary:
	_baseline_rejections[reason] = int(_baseline_rejections.get(reason, 0)) + 1
	var result := {
		"applied": false,
		"reason": reason,
		"tick": tick,
		"player_count": 0,
	}
	_last_rejection = result.duplicate(true)
	baseline_rejected.emit(result.duplicate(true))
	return result

func _physics_process(delta: float) -> void:
	if not _configured or _session_closed or session == null or not session.is_active():
		return
	if not _host_authority:
		if client_view != null:
			client_view.tick(delta)
			_apply_all_replicas()
		return
	_physics_frames += 1
	_step_authority(delta)

func _step_authority(delta: float) -> void:
	_step_accumulator += maxf(delta, 0.0)
	var steps := 0
	while _step_accumulator + EPSILON >= FIXED_STEP and steps < MAX_CATCHUP_STEPS:
		_consume_commands()
		authority.step()
		_send_combat()
		_authority_steps += 1
		# A late joiner is seeded from exactly this authority tick, after the
		# step, so the reliable baseline is a complete and atomic state.
		_flush_pending_baselines()
		_step_accumulator -= FIXED_STEP
		_snapshot_accumulator += FIXED_STEP
		while _snapshot_accumulator + EPSILON >= SNAPSHOT_INTERVAL:
			_snapshot_accumulator -= SNAPSHOT_INTERVAL
			_send_snapshot()
		steps += 1

func _consume_commands() -> void:
	var records: Array = session.drain_commands()
	for record_variant: Variant in records:
		if not (record_variant is Dictionary):
			continue
		var record: Dictionary = record_variant
		var player_id := StringName(String(record.get("player_id", "")))
		var command_variant: Variant = record.get("command", {})
		if player_id == &"" or not (command_variant is Dictionary):
			continue
		var command: Dictionary = command_variant
		if command.is_empty():
			continue
		var key := String(player_id)
		if not _actors.has(key):
			_authority_rejected_commands += 1
			continue
		_consumed_commands += 1
		if authority.submit_command(player_id, command, int(record.get("sequence", -1))):
			_command_counts[key] = int(_command_counts.get(key, 0)) + 1
		else:
			_authority_rejected_commands += 1

func _flush_pending_baselines() -> void:
	if _pending_baseline_peers.is_empty() or session == null or authority == null:
		return
	var baseline := _build_baseline()
	if baseline.is_empty():
		return
	for peer_variant: Variant in _pending_baseline_peers.keys():
		var peer_id := int(peer_variant)
		if session.send_baseline(peer_id, baseline) != OK:
			continue
		_pending_baseline_peers.erase(peer_id)
		_baseline_sent_count += 1
		_last_baseline_sent = baseline.duplicate(true)
		baseline_sent.emit(peer_id, baseline.duplicate(true))

func _build_baseline() -> Dictionary:
	if session == null or authority == null:
		return {}
	var players: Dictionary = authority.get_snapshots()
	if players.is_empty():
		return {}
	var tick: int = authority.get_tick()
	return {
		"match_epoch": session.get_match_epoch(),
		"baseline_tick": tick,
		"server_tick": tick,
		"players": players,
		"combat": authority.get_combat_state(),
	}

func _send_snapshot() -> void:
	if session == null or authority == null:
		return
	var players: Dictionary = authority.get_snapshots()
	if players.is_empty():
		return
	var batch := {
		"match_epoch": session.get_match_epoch(),
		"server_tick": authority.get_tick(),
		"players": players,
		"combat": authority.get_combat_state(),
	}
	if session.broadcast_snapshot_batch(batch) != OK:
		return
	_snapshots_sent += 1
	_last_snapshot_tick = int(batch["server_tick"])
	_last_snapshot_batch = batch.duplicate(true)

func _on_snapshot_batch_received(batch: Dictionary) -> void:
	apply_snapshot_batch(batch)

func _on_baseline_received(baseline: Dictionary) -> void:
	apply_baseline(baseline)

func _on_session_baseline_rejected(result: Dictionary) -> void:
	var reason := String(result.get("reason", "invalid_baseline"))
	var tick := int(result.get("tick", -1))
	_record_baseline_rejection(reason, tick)

func _on_player_joined(peer_id: int, _player_id: String) -> void:
	if not _host_authority or peer_id <= 1:
		return
	_pending_baseline_peers[peer_id] = true

func _on_player_left(peer_id: int, _player_id: String) -> void:
	_pending_baseline_peers.erase(peer_id)

func _on_session_closed() -> void:
	if _session_closed:
		return
	_session_closed = true
	if is_instance_valid(pellet_view):
		pellet_view.clear()
		pellet_view.set_process(false)
	combat_replica.clear()
	_pending_combat_packet.clear()
	_combat_active = false
	_pending_baseline_peers.clear()
	if replica != null:
		replica.deactivate()
	if client_view != null:
		client_view.deactivate("session_closed")
	# Fall back to the last authoritative replica for presentation once the
	# presentation buffers are gone, instead of leaving a frozen predicted pose.
	_apply_all_replicas()
	session_closed.emit()
	combat_state_changed.emit(false)

func _on_identity_assigned(_identity: Dictionary) -> void:
	_set_local_identity()

func _set_local_identity() -> void:
	if session == null:
		return
	var identity: Dictionary = session.get_local_identity()
	if identity.is_empty():
		return
	_local_player_id = StringName(String(identity.get("player_id", "")))
	if not _host_authority and not replica.has_baseline():
		combat_replica.configure(session.get_match_epoch())
	if not _host_authority and replica != null and not replica.has_baseline():
		replica.configure(session.get_match_epoch())
	if not _host_authority and client_view != null and _local_player_id != &"":
		client_view.set_local_player(_local_player_id)

## The predicted step must use the same CharacterMotor speed as the real actor.
## The motor's exported speed remains the single authority for movement.
func _configure_prediction_speed(actor: Node) -> void:
	if client_view == null or not actor.has_method("get_motor"):
		return
	var motor: Variant = actor.get_motor()
	if not is_instance_valid(motor):
		return
	var speed: Variant = motor.get("speed")
	if speed is float or speed is int:
		client_view.set_movement_speed(float(speed))

func _apply_all_replicas() -> void:
	if replica == null:
		return
	var states: Dictionary
	if not _host_authority and client_view != null:
		states = client_view.get_render_states()
		if states.is_empty():
			states = replica.get_states()
	else:
		states = replica.get_states()
	for key: String in _actors.keys():
		var state: Dictionary = states.get(key, {}).duplicate(true)
		var combat_player: Dictionary = combat_replica.get_player(key)
		if not combat_player.is_empty():
			state["health"] = combat_player.get("health", state.get("health", 0.0))
			state["dead"] = combat_player.get("dead", state.get("dead", false))
		_apply_state_to_actor(_actors[key], state)

func _apply_replica_state(player_id: String) -> void:
	if replica == null:
		return
	var actor: Variant = _actors.get(player_id)
	if not is_instance_valid(actor):
		return
	var state: Dictionary
	if not _host_authority and client_view != null:
		state = client_view.get_render_state(StringName(player_id))
	else:
		state = replica.get_state(StringName(player_id))
	_apply_state_to_actor(actor, state)

func _apply_state_to_actor(actor: Node, state: Dictionary) -> void:
	if state.is_empty() or not is_instance_valid(actor):
		return
	if actor.has_method("apply_replica_state"):
		actor.apply_replica_state(state)
		return
	if actor is Node2D and state.has("position"):
		(actor as Node2D).global_position = state["position"]
	if actor is CharacterBody2D and state.has("velocity"):
		(actor as CharacterBody2D).velocity = state["velocity"]
	if state.has("dead") and actor.get("is_dead") != null:
		actor.set("is_dead", bool(state["dead"]))
	if state.has("health") and actor.get("real_hp") != null:
		actor.set("real_hp", float(state["health"]))

func submit_fire(direction: Vector2) -> int:
	return submit_command({"type": "fire", "direction": direction})

func get_combat_state() -> Dictionary:
	if _session_closed:
		return {}
	return authority.get_combat_state() if _host_authority else combat_replica.get_state()

func _send_combat() -> void:
	var state: Dictionary = authority.get_combat_state()
	if int(state.revision) <= _sent_combat_revision:
		return
	_sent_combat_revision = int(state.revision)
	var packet := {"match_epoch": session.get_match_epoch(), "server_tick": authority.get_tick(),
		"combat": state, "players": authority.get_snapshots()}
	session.broadcast_combat_state(packet)
	combat_updated.emit(state.duplicate(true))

func _on_combat_packet(packet: Dictionary) -> void:
	if _host_authority or _session_closed:
		return
	if not replica.has_baseline():
		if int(packet.get("server_tick", -1)) >= int(_pending_combat_packet.get("server_tick", -1)):
			_pending_combat_packet = packet.duplicate(true)
		return
	if not combat_replica.apply_packet(packet):
		return
	# CombatReplica owns the packet's absolute health/death checkpoint. Movement
	# remains on SnapshotReplica's regular stream, so a combat packet never
	# produces a duplicate or regressed movement-snapshot rejection.
	_apply_all_replicas()
	combat_updated.emit(combat_replica.get_state())
