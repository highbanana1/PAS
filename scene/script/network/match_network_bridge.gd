class_name MatchNetworkBridge
extends Node

## Small bridge between NetworkSession's validated command transport and
## MatchAuthority's gameplay seam. On the host it drains trusted command
## records, submits them to the authority, steps at 60 Hz and broadcasts
## snapshot batches at 20 Hz. On a client it submits local intents through the
## same session envelope path and applies authoritative batches to an
## observable replica. It never predicts, interpolates or decides gameplay.

signal replicas_updated(batch: Dictionary)
signal snapshot_rejected(result: Dictionary)

const MatchAuthorityScript = preload("res://scene/script/network/match_authority.gd")
const SnapshotReplicaScript = preload("res://scene/script/network/snapshot_replica.gd")

const AUTHORITY_HZ: int = 60
const SNAPSHOT_HZ: int = 20
const FIXED_STEP: float = 1.0 / 60.0
const SNAPSHOT_INTERVAL: float = 1.0 / 20.0
const MAX_CATCHUP_STEPS: int = 8
const EPSILON: float = 0.000001

var session
var authority
var replica

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

func configure(session_node: Node, authority_instance = null) -> bool:
	if _configured or not is_instance_valid(session_node):
		return false
	if not session_node.has_method("is_host") or not session_node.has_method("is_active"):
		return false
	if not session_node.is_active():
		return false
	session = session_node
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
	else:
		if not session.snapshot_batch_received.is_connected(_on_snapshot_batch_received):
			session.snapshot_batch_received.connect(_on_snapshot_batch_received)
		if not session.identity_assigned.is_connected(_on_identity_assigned):
			session.identity_assigned.connect(_on_identity_assigned)
		_set_local_identity()
	_configured = true
	return true

func is_host_authority() -> bool:
	return _host_authority

func get_authority():
	return authority

func get_local_player_id() -> StringName:
	return _local_player_id

## Both host-local and client-local intents use this single entrance. For the
## host, NetworkSession immediately validates the envelope into its command
## queue; for a client, the same envelope goes to the server. Neither path
## bypasses MatchAuthority.
func submit_command(command: Dictionary) -> int:
	if not _configured or session == null or not session.is_active() or command.is_empty():
		return -1
	var sequence := int(session.send_command(command))
	if sequence > 0:
		_submitted_commands += 1
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

## Client reception path. Public so a test or fixture can feed the same replica
## used by the transport RPC. Returns the SnapshotReplica result dictionary.
func apply_snapshot_batch(batch: Dictionary) -> Dictionary:
	if not _configured or _host_authority or replica == null:
		return {"applied": false, "reason": "not_client", "tick": -1, "player_count": 0}
	var result: Dictionary = replica.apply_batch(batch)
	if not bool(result.get("applied", false)):
		_last_rejection = result.duplicate(true)
		snapshot_rejected.emit(result.duplicate(true))
		return result
	_last_applied_batch = batch.duplicate(true)
	_last_applied_tick = int(result.get("tick", -1))
	_apply_all_replicas()
	replicas_updated.emit(batch.duplicate(true))
	return result

func _physics_process(delta: float) -> void:
	if not _configured or session == null or not session.is_active():
		return
	if not _host_authority:
		return
	_physics_frames += 1
	_step_authority(delta)

func _step_authority(delta: float) -> void:
	_step_accumulator += maxf(delta, 0.0)
	var steps := 0
	while _step_accumulator + EPSILON >= FIXED_STEP and steps < MAX_CATCHUP_STEPS:
		_consume_commands()
		authority.step()
		_authority_steps += 1
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
		if authority.submit_command(player_id, command):
			_command_counts[key] = int(_command_counts.get(key, 0)) + 1
		else:
			_authority_rejected_commands += 1

func _send_snapshot() -> void:
	if session == null or authority == null:
		return
	var players: Dictionary = {}
	for key: String in _actors.keys():
		var snapshot: Dictionary = authority.get_snapshot(StringName(key))
		if snapshot.is_empty():
			continue
		players[key] = snapshot
	if players.is_empty():
		return
	var batch := {
		"match_epoch": session.get_match_epoch(),
		"server_tick": authority.get_tick(),
		"players": players,
	}
	if session.broadcast_snapshot_batch(batch) != OK:
		return
	_snapshots_sent += 1
	_last_snapshot_tick = int(batch["server_tick"])
	_last_snapshot_batch = batch.duplicate(true)

func _on_snapshot_batch_received(batch: Dictionary) -> void:
	apply_snapshot_batch(batch)

func _on_identity_assigned(_identity: Dictionary) -> void:
	_set_local_identity()

func _set_local_identity() -> void:
	if session == null:
		return
	var identity: Dictionary = session.get_local_identity()
	if identity.is_empty():
		return
	_local_player_id = StringName(String(identity.get("player_id", "")))
	if not _host_authority and replica != null:
		replica.configure(session.get_match_epoch())

func _apply_all_replicas() -> void:
	if replica == null:
		return
	var states: Dictionary = replica.get_states()
	for key: String in _actors.keys():
		_apply_state_to_actor(_actors[key], states.get(key, {}))

func _apply_replica_state(player_id: String) -> void:
	if replica == null:
		return
	var actor: Variant = _actors.get(player_id)
	if not is_instance_valid(actor):
		return
	_apply_state_to_actor(actor, replica.get_state(StringName(player_id)))

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
