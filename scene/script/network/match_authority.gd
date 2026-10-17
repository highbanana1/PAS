class_name MatchAuthority
extends RefCounted

## Host-authoritative match rules for one match. Callers register actors, bind
## player ids to movement intents, advance fixed steps, and read snapshots or
## lifecycle events. Command queues and timing stay inside this module.

const FIXED_STEP: float = 1.0 / 60.0

var _players: Dictionary = {}
var _events: Array[Dictionary] = []
var _tick: int = 0

func register_player(player_id: StringName, actor: Node, config: Dictionary = {}) -> bool:
	if player_id == &"" or not is_instance_valid(actor) or _players.has(player_id):
		return false
	if not actor.has_method("get_motor"):
		return false
	if config.has("spawn_position"):
		var configured_spawn: Variant = config["spawn_position"]
		if configured_spawn is Vector2 and configured_spawn.is_finite() and actor.get("spawn_position") != null:
			actor.set("spawn_position", configured_spawn)
	var record: Dictionary = {
		"id": player_id,
		"actor": actor,
		"move_input": Vector2.ZERO,
		"actions": [],
		"dead": actor.get("is_dead") == true,
		"respawn_remaining": 0.0,
		"revision": 0,
	}
	if bool(record["dead"]):
		record["respawn_remaining"] = _respawn_delay(actor)
	_players[player_id] = record
	if actor.has_method("set_authority_controlled"):
		actor.set_authority_controlled(true)
	_emit_event("player_registered", record, {"position": _actor_position(actor)})
	return true

func unregister_player(player_id: StringName) -> bool:
	if not _players.has(player_id):
		return false
	var record: Dictionary = _players[player_id]
	_players.erase(player_id)
	_clear_actions(record)
	_emit_event("player_unregistered", record, {})
	return true

func submit_command(player_id: StringName, command: Dictionary) -> bool:
	if not _players.has(player_id) or command.is_empty():
		return false
	var record: Dictionary = _players[player_id]
	var command_type := StringName(command.get("type", ""))
	match command_type:
		&"move":
			record["move_input"] = _requested_direction(command, record["move_input"])
			return true
		&"jump":
			if not _accepts_actions(record):
				return false
			var actions: Array = record["actions"]
			actions.append({"type": &"jump"})
			return true
		&"dash":
			if not _accepts_actions(record):
				return false
			var actions: Array = record["actions"]
			actions.append({
				"type": &"dash",
				"direction": _requested_direction(command, Vector2.ZERO),
			})
			return true
		_:
			return false

func step() -> void:
	_tick += 1
	for player_id: StringName in _players.keys():
		_step_player(_players[player_id])

func get_snapshot(player_id: StringName) -> Dictionary:
	if not _players.has(player_id):
		return {}
	var record: Dictionary = _players[player_id]
	if not is_instance_valid(record.get("actor")):
		return {}
	var actor: Node = record["actor"]
	var motor: Node = actor.get_motor()
	return {
		"player_id": String(player_id),
		"tick": _tick,
		"revision": int(record["revision"]),
		"position": _actor_position(actor),
		"velocity": _actor_velocity(actor),
		"on_floor": _actor_on_floor(actor),
		"is_dashing": motor.is_dashing,
		"can_dash": motor.can_dash,
		"jump_count": motor.jump_count,
		"dead": actor.get("is_dead") == true,
		"health": _actor_health(actor, "real_hp"),
		"max_health": _actor_health(actor, "max_hp"),
		"respawn_remaining": float(record["respawn_remaining"]),
	}

func drain_events() -> Array[Dictionary]:
	var result: Array[Dictionary] = []
	result.append_array(_events)
	_events.clear()
	return result

func _step_player(record: Dictionary) -> void:
	if not is_instance_valid(record.get("actor")):
		_clear_actions(record)
		return
	var actor: Node = record["actor"]
	if actor.get("is_dead") == true:
		_step_dead(record, actor)
		return
	if bool(record["dead"]):
		record["dead"] = false
		record["respawn_remaining"] = 0.0
		_clear_actions(record)
		_emit_event("player_respawned", record, {})
	_apply_actions(record, actor)
	if actor is CharacterBody2D and actor.is_physics_processing():
		var motor: Node = actor.get_motor()
		motor.tick(FIXED_STEP, record["move_input"])
		(actor as CharacterBody2D).move_and_slide()
	record["revision"] = int(record["revision"]) + 1

func _step_dead(record: Dictionary, actor: Node) -> void:
	_clear_actions(record)
	var remaining := float(record["respawn_remaining"])
	if not bool(record["dead"]):
		record["dead"] = true
		remaining = _respawn_delay(actor)
		_emit_event("player_died", record, {})
	remaining = maxf(remaining - FIXED_STEP, 0.0)
	record["respawn_remaining"] = remaining
	_set_respawn_remaining(actor, remaining)
	record["revision"] = int(record["revision"]) + 1
	if remaining <= 0.0:
		if actor.has_method("respawn"):
			actor.respawn(_spawn_position(record, actor))
		record["dead"] = false
		record["respawn_remaining"] = 0.0
		_emit_event("player_respawned", record, {})

func _accepts_actions(record: Dictionary) -> bool:
	if is_instance_valid(record.get("actor")) and not bool(record["dead"]):
		var actor: Node = record["actor"]
		if actor.get("is_dead") != true:
			return true
	_clear_actions(record)
	return false

func _clear_actions(record: Dictionary) -> void:
	var actions: Array = record["actions"]
	actions.clear()

func _apply_actions(record: Dictionary, actor: Node) -> void:
	var actions: Array = record["actions"]
	if actions.is_empty():
		return
	var motor: Node = actor.get_motor()
	for action: Dictionary in actions:
		match StringName(action.get("type", "")):
			&"jump":
				motor.request_jump()
			&"dash":
				motor.request_dash(action.get("direction", Vector2.ZERO))
	actions.clear()

func _requested_direction(command: Dictionary, fallback: Vector2) -> Vector2:
	var requested: Variant = command.get("direction", fallback)
	if requested is Vector2 and requested.is_finite():
		return requested.limit_length(1.0)
	return fallback

func _respawn_delay(actor: Node) -> float:
	var value: Variant = actor.get("respawn_delay")
	if value is float or value is int:
		return maxf(float(value), 0.05)
	return 5.0

func _spawn_position(record: Dictionary, actor: Node) -> Vector2:
	var value: Variant = actor.get("spawn_position")
	if value is Vector2 and value.is_finite():
		return value
	var fallback: Variant = record.get("spawn_position", Vector2.ZERO)
	return fallback if fallback is Vector2 else Vector2.ZERO

func _set_respawn_remaining(actor: Node, seconds: float) -> void:
	if not actor.has_method("get_respawn_component"):
		return
	var lifecycle: Node = actor.get_respawn_component()
	if is_instance_valid(lifecycle) and lifecycle.has_method("set_authority_remaining"):
		lifecycle.set_authority_remaining(seconds)

func _actor_position(actor: Node) -> Vector2:
	return (actor as Node2D).global_position if actor is Node2D else Vector2.ZERO

func _actor_velocity(actor: Node) -> Vector2:
	return (actor as CharacterBody2D).velocity if actor is CharacterBody2D else Vector2.ZERO

func _actor_on_floor(actor: Node) -> bool:
	return (actor as CharacterBody2D).is_on_floor() if actor is CharacterBody2D else false

func _actor_health(actor: Node, property_name: String) -> float:
	var value: Variant = actor.get(property_name)
	return float(value) if value is float or value is int else 0.0

func _emit_event(event_type: String, record: Dictionary, extra: Dictionary = {}) -> void:
	var event: Dictionary = {
		"type": event_type,
		"player_id": String(record["id"]),
		"tick": _tick,
	}
	event.merge(extra, true)
	_events.append(event)
