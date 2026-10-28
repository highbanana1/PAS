class_name MatchAuthority
extends RefCounted

## Host-authoritative match rules for one match. Callers register actors, bind
## player ids to movement intents, advance fixed steps, and read snapshots or
## lifecycle events. Command queues and timing stay inside this module.

const FIXED_STEP: float = 1.0 / 60.0
const Rules = preload("res://scene/script/combat/melee_guard_rules.gd")

var _shotgun = preload("res://scene/script/network/shotgun_authority.gd").new()
var _melee = preload("res://scene/script/network/melee_authority.gd").new()
var _items = preload("res://scene/script/network/item_authority.gd").new()
var _extraction = preload("res://scene/script/network/extraction_authority.gd").new()
var _match = preload("res://scene/script/network/match_lifecycle.gd").new()
var _guard_script = preload("res://scene/script/network/guard_authority.gd")

var _players: Dictionary = {}
var _events: Array[Dictionary] = []
var _tick: int = 0
var _domain_revision: int = 0
var _seen_shot_revision: int = 0
var _seen_melee_revision: int = 0
var _seen_item_revision: int = 0
var _seen_extraction_revision: int = 0
var _seen_match_revision: int = 0

func register_player(player_id: StringName, actor: Node, config: Dictionary = {}) -> bool:
	if player_id == &"" or not is_instance_valid(actor) or _players.has(player_id):
		return false
	if not actor.has_method("get_motor"):
		return false
	var phase := String(_match.get_state().get("phase", "waiting"))
	if phase == "ended" or (phase == "running" and not _match.record_join(player_id)):
		return false
	if config.has("spawn_position"):
		var configured_spawn: Variant = config["spawn_position"]
		if configured_spawn is Vector2 and configured_spawn.is_finite() and actor.get("spawn_position") != null:
			actor.set("spawn_position", configured_spawn)
	var life_id: int = maxi(int(config.get("life_id", 1)), 1)
	var combat_config := _combat_config(actor, config)
	var guard = _guard_script.new()
	guard.configure(combat_config.guard, life_id)
	_melee.configure_player(player_id, combat_config.sword)
	var record: Dictionary = {
		"id": player_id,
		"actor": actor,
		"move_input": Vector2.ZERO,
		"actions": [],
		"dead": actor.get("is_dead") == true,
		"respawn_remaining": 0.0,
		"revision": 0,
		"last_sequence": -1,
		"life_id": life_id,
		"guard": guard,
		"extracted": false,
		"online": true,
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
	_match.record_removed(player_id)
	_extraction.release_player(player_id, _actor_position(record["actor"]) if is_instance_valid(record.get("actor")) else Vector2.ZERO)
	_players.erase(player_id)
	_melee.remove_player(player_id)
	_clear_actions(record)
	_emit_event("player_unregistered", record, {})
	return true

## A transport loss does not remove the combat actor. Stop held input at once,
## while death, respawn and extraction continue on the host clock.
func suspend_player(player_id: StringName) -> bool:
	if not _players.has(player_id): return false
	var record: Dictionary = _players[player_id]
	if not bool(record["online"]): return false
	record["online"] = false
	record["move_input"] = Vector2.ZERO
	_clear_actions(record)
	record["guard"].cancel()
	_touch_domain()
	_emit_event("player_suspended", record)
	return true

func resume_player(player_id: StringName) -> bool:
	if not _players.has(player_id): return false
	var record: Dictionary = _players[player_id]
	if bool(record["online"]): return false
	record["online"] = true
	record["move_input"] = Vector2.ZERO
	# The new transport starts sequence numbering at one; acknowledgements must
	# share that new sequence domain for client prediction to reconcile.
	record["last_sequence"] = 0
	_clear_actions(record)
	_touch_domain()
	_emit_event("player_resumed", record)
	return true

## Called once when the reserved seat expires. ItemAuthority's drop is
## idempotent if death has already dropped the inventory. unregister_player
## releases any carried/bound star and clears the extraction point.
func expire_player(player_id: StringName) -> bool:
	if not _players.has(player_id): return false
	var record: Dictionary = _players[player_id]
	if bool(record["online"]): return false
	var actor: Variant = record.get("actor")
	var position: Vector2 = _actor_position(actor) if is_instance_valid(actor) else Vector2.ZERO
	var dropped: Array = _items.drop_inventory(player_id, int(record["life_id"]), position)
	_emit_event("player_reservation_expired", record, {"dropped_items": dropped})
	return unregister_player(player_id)

func _combat_config(actor: Node, registration: Dictionary) -> Dictionary:
	var candidate: Variant = registration.get("combat_rules", {})
	if (not candidate is Dictionary or (candidate as Dictionary).is_empty()) \
			and actor.has_method("get_authority_combat_config"):
		candidate = actor.get_authority_combat_config()
	if candidate is Dictionary:
		return Rules.validated_config(candidate)
	return Rules.new().to_authority_config()

## Host map/setup API. The module stores only stable ids and value snapshots.
func configure_extraction(seconds: float = 30.0) -> bool:
	return _extraction.configure(seconds)

func register_star(star_id: StringName, position: Vector2) -> bool:
	var accepted: bool = _extraction.register_star(star_id, position)
	if accepted: _touch_domain()
	return accepted

func register_extraction_point(point_id: StringName, position: Vector2,
		radius: float = 48.0) -> bool:
	var accepted: bool = _extraction.register_point(point_id, position, radius)
	if accepted: _touch_domain()
	return accepted

func get_extraction_state() -> Dictionary:
	return _extraction.get_state()

## Freeze the actual registered opening roster and selected map supply.
## Lobby/map code must register exactly ceil(opening players / 4) stars first.
func start_match(duration_ticks: int = 36000) -> bool:
	if duration_ticks <= 0 or duration_ticks > 36000: return false
	var opening_ids: Array = _players.keys()
	var extraction: Dictionary = _extraction.get_state()
	var star_ids: Array = extraction.get("stars", {}).keys()
	if opening_ids.is_empty() or opening_ids.size() > 16 \
			or star_ids.size() != ceili(float(opening_ids.size()) / 4.0) \
			or extraction.get("points", {}).is_empty():
		return false
	if not _match.configure(duration_ticks): return false
	var started: bool = _match.start(opening_ids, star_ids, _tick)
	if started: _touch_domain()
	return started

func get_match_state() -> Dictionary:
	return _match.get_state()

func _extraction_players() -> Dictionary:
	var players: Dictionary = {}
	for player_id: StringName in _players:
		var record: Dictionary = _players[player_id]
		var actor: Variant = record.get("actor")
		if not is_instance_valid(actor):
			continue
		players[player_id] = {
			"position": _actor_position(actor),
			"alive": actor.get("is_dead") != true and not bool(record["dead"]),
			"spectating": bool(record["extracted"]),
			"life_id": int(record["life_id"]),
		}
	return players

func _complete_extraction(player_id: StringName) -> void:
	if not _players.has(player_id): return
	var record: Dictionary = _players[player_id]
	if bool(record["extracted"]): return
	record["extracted"] = true
	_clear_actions(record)
	record["move_input"] = Vector2.ZERO
	record["guard"].cancel()
	_melee.reset_player(player_id, int(record["life_id"]))
	_shotgun.cancel_player(player_id)
	var actor: Node = record["actor"]
	if is_instance_valid(actor):
		if actor.has_method("set_extracted"):
			actor.set_extracted(true)
		elif actor is CollisionObject2D:
			(actor as CollisionObject2D).collision_layer = 0
			(actor as CollisionObject2D).collision_mask = 0
	_touch_domain()
	_emit_event("player_extracted", record, {})

## sequence is the NetworkSession envelope sequence when present. It is echoed
## in snapshots as ack_sequence so a client can drop exactly the confirmed
## predicted inputs without replaying them again. Gameplay never trusts it.
## Client payload fields such as damage, target id, final guard value, health,
## item owner or revision are never read as facts.
func submit_command(player_id: StringName, command: Dictionary, sequence: int = -1) -> bool:
	if bool(_match.get_state().get("ended", false)): return false
	if not _players.has(player_id) or command.is_empty():
		return false
	var record: Dictionary = _players[player_id]
	var command_type := StringName(command.get("type", ""))
	match command_type:
		&"fire":
			if not _accepts_actions(record):
				return false
			var accepted: bool = _shotgun.request_fire(player_id, record["actor"], command.get("direction"), _tick)
			if accepted:
				# Attack-cancels-guard applies to every weapon, not only the
				# sword. Clear both the active guard and its held input so a
				# later tick cannot silently raise it again.
				record["guard"].cancel()
				_touch_domain()
				_acknowledge(record, sequence)
			return accepted
		&"sword":
			if not _accepts_actions(record) or not command.has("action_id"):
				return false
			var action_id := int(command.get("action_id", 0))
			if action_id <= 0:
				return false
			var accepted_sword: bool = _melee.request_sword(
				player_id, record["actor"], command.get("direction"), action_id,
				_tick, int(record["life_id"]), record["guard"])
			if accepted_sword:
				_touch_domain()
				_acknowledge(record, sequence)
			return accepted_sword
		&"guard":
			if not _accepts_actions(record):
				return false
			var enabled := bool(command.get("enabled", false))
			var facing: Variant = command.get("direction", Vector2.ZERO)
			if enabled and (not facing is Vector2 or not (facing as Vector2).is_finite()
					or (facing as Vector2).is_zero_approx()):
				return false
			# Match the offline controller: a swing and its recovery window cannot
			# be interrupted by held guard input.
			if enabled and _melee.is_busy(player_id, _tick):
				return false
			var requested: bool = record["guard"].request(
				enabled, facing if facing is Vector2 else Vector2.ZERO,
				true, int(record["life_id"]))
			if requested:
				_touch_domain()
				_acknowledge(record, sequence)
			return requested
		&"pickup":
			if not _accepts_actions(record):
				return false
			var item_id := int(command.get("item_id", -1))
			if item_id <= 0:
				return false
			var pickup: Dictionary = _items.request_pickup(
				player_id, item_id, _actor_position(record["actor"]), true,
				int(command.get("expected_revision", -1)))
			if bool(pickup.get("accepted", false)):
				_touch_domain()
				_acknowledge(record, sequence)
				return true
			return false
		&"star_pickup":
			if not _accepts_actions(record): return false
			var star_id := StringName(String(command.get("star_id", "")))
			var accepted_star: bool = _extraction.request_pickup(
				player_id, star_id, int(command.get("expected_revision", -1)),
				_extraction_players().get(player_id, {}))
			if accepted_star:
				_touch_domain()
				_acknowledge(record, sequence)
			return accepted_star
		&"deliver_star":
			if not _accepts_actions(record): return false
			var point_id := StringName(String(command.get("point_id", "")))
			var accepted_delivery: bool = _extraction.request_delivery(
				player_id, point_id, int(command.get("expected_revision", -1)),
				_extraction_players().get(player_id, {}), _tick)
			if accepted_delivery:
				_touch_domain()
				_acknowledge(record, sequence)
			return accepted_delivery
		&"use_item":
			if not _accepts_actions(record):
				return false
			var use_item_id := int(command.get("item_id", -1))
			var use_mode := String(command.get("mode", ""))
			var use_amount: Variant = command.get("amount", 0.0)
			if use_item_id <= 0 or use_mode.is_empty():
				return false
			if not (use_amount is float or use_amount is int):
				return false
			var use: Dictionary = _items.request_use(
				player_id, use_item_id, int(command.get("expected_revision", -1)),
				use_mode, float(use_amount), record["actor"])
			if bool(use.get("accepted", false)):
				_touch_domain()
				_acknowledge(record, sequence)
				return true
			return false
		&"move":
			if not _accepts_actions(record): return false
			record["move_input"] = _requested_direction(command, record["move_input"])
			_acknowledge(record, sequence)
			return true
		&"jump":
			if not _accepts_actions(record):
				return false
			var actions: Array = record["actions"]
			actions.append({"type": &"jump"})
			_acknowledge(record, sequence)
			return true
		&"dash":
			if not _accepts_actions(record):
				return false
			var dash_actions: Array = record["actions"]
			dash_actions.append({
				"type": &"dash",
				"direction": _requested_direction(command, Vector2.ZERO),
			})
			_acknowledge(record, sequence)
			return true
		_:
			return false

func _acknowledge(record: Dictionary, sequence: int) -> void:
	if sequence > int(record.get("last_sequence", -1)):
		record["last_sequence"] = sequence

func step() -> void:
	_tick += 1
	if bool(_match.get_state().get("ended", false)): return
	# Complete a deadline against the previous stable position and life before
	# this tick's movement or lethal attacks. This defines the same-tick tie.
	for winner: StringName in _extraction.step(_tick, _extraction_players()):
		_complete_extraction(winner)
	for player_id: StringName in _players.keys():
		_step_player(_players[player_id])
	# All actors moved for this tick before melee and pellets resolve. Deaths
	# caused by weapon damage are observed by the lifecycle on the next tick.
	_melee.step(_tick, _players)
	_shotgun.step(_tick, _players)
	# Post-combat pass only cancels bindings or drops on death; never awards wins.
	_extraction.reconcile(_extraction_players())
	_match.step(_tick, _extraction.get_state())
	_sync_domain_revisions()

func get_tick() -> int:
	return _tick

func get_player_ids() -> Array[StringName]:
	var result: Array[StringName] = []
	for player_id: StringName in _players.keys():
		result.append(player_id)
	return result

## Complete authoritative snapshot set for one authority tick. The bridge uses
## it to build a baseline and periodic batches from the same source of truth.
func get_snapshots() -> Dictionary:
	var result: Dictionary = {}
	for player_id: StringName in _players.keys():
		var snapshot: Dictionary = get_snapshot(player_id)
		if snapshot.is_empty():
			continue
		result[String(player_id)] = snapshot
	return result

## The unreliable 20 Hz stream carries only fields needed for motion,
## prediction, life transitions, and the live respawn countdown. Full player
## state stays in the reliable baseline and revisioned combat checkpoints.
func get_movement_snapshots() -> Dictionary:
	var result: Dictionary = {}
	for player_id: StringName in _players.keys():
		var full: Dictionary = get_snapshot(player_id)
		if full.is_empty(): continue
		var compact: Dictionary = {}
		for field: String in ["player_id", "tick", "revision", "position", "velocity",
				"dead", "extracted", "life_id", "ack_sequence", "respawn_remaining",
				"health", "max_health"]:
			compact[field] = full[field]
		result[String(player_id)] = compact
	return result

## Reliable combat checkpoints keep only player fields that must survive loss
## of the movement stream. Motion, guard and inventory data already travel in
## their dedicated domains and must not be duplicated in every combat packet.
func get_combat_snapshots() -> Dictionary:
	var result: Dictionary = {}
	for player_id: StringName in _players.keys():
		var full: Dictionary = get_snapshot(player_id)
		if full.is_empty(): continue
		var compact: Dictionary = {}
		for field: String in ["player_id", "tick", "revision", "dead", "online",
				"extracted", "spectating", "health", "max_health", "life_id"]:
			compact[field] = full[field]
		result[String(player_id)] = compact
	return result

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
		"online": bool(record["online"]),
		"extracted": bool(record["extracted"]),
		"spectating": bool(record["extracted"]),
		"health": _actor_health(actor, "real_hp"),
		"max_health": _actor_health(actor, "max_hp"),
		"respawn_remaining": float(record["respawn_remaining"]),
		"ack_sequence": int(record.get("last_sequence", -1)),
		"life_id": int(record["life_id"]),
		"guard": record["guard"].get_state(),
		"items": _items.get_inventory(player_id),
	}

func drain_events() -> Array[Dictionary]:
	var result: Array[Dictionary] = []
	result.append_array(_events)
	_events.clear()
	return result

func get_guard_state(player_id: StringName) -> Dictionary:
	if not _players.has(player_id):
		return {}
	return _players[player_id]["guard"].get_state()

func get_item_state() -> Dictionary:
	return _items.get_state()

func get_item(item_id: int) -> Dictionary:
	return _items.get_item(item_id)

func get_world_items() -> Array:
	return _items.get_world_items()

## Host-only setup/probe seam for a backpack item. Values are already validated
## numeric state; ownership is assigned by the host, never by a client command.
func grant_item(player_id: StringName, item_type: Variant, remaining: float, capacity: float) -> int:
	if not _players.has(player_id):
		return -1
	var item_id: int = _items.grant(player_id, item_type, remaining, capacity)
	if item_id > 0:
		_touch_domain()
	return item_id

func _step_player(record: Dictionary) -> void:
	if bool(record["extracted"]):
		return
	if not is_instance_valid(record.get("actor")):
		_clear_actions(record)
		return
	var actor: Node = record["actor"]
	if actor.get("is_dead") == true:
		_step_dead(record, actor)
		return
	if bool(record["dead"]):
		# Compatibility path: an actor respawned outside the authority still
		# advances the stable life and refreshes authority-owned combat state.
		record["dead"] = false
		record["respawn_remaining"] = 0.0
		record["life_id"] = int(record["life_id"]) + 1
		record["guard"].reset(int(record["life_id"]))
		_melee.reset_player(record["id"], int(record["life_id"]))
		_clear_actions(record)
		_touch_domain()
		_emit_event("player_respawned", record, {"life_id": int(record["life_id"])})
	var guard_before: Dictionary = record["guard"].get_state()
	var guard_changed: bool = record["guard"].tick(FIXED_STEP)
	if guard_changed:
		var guard_after: Dictionary = record["guard"].get_state()
		if _tick % 3 == 0 \
				or bool(guard_before.get("is_guarding", false)) != bool(guard_after.get("is_guarding", false)) \
				or bool(guard_before.get("exhausted", false)) != bool(guard_after.get("exhausted", false)) \
				or is_zero_approx(float(guard_after.get("value", 0.0))) \
				or is_equal_approx(float(guard_after.get("value", 0.0)), float(guard_after.get("maximum", 100.0))):
			_touch_domain()
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
		record["guard"].cancel()
		_melee.reset_player(record["id"], int(record["life_id"]))
		var dropped: Array = _items.drop_inventory(
			record["id"], int(record["life_id"]), _actor_position(actor))
		_touch_domain()
		_emit_event("player_died", record, {
			"life_id": int(record["life_id"]),
			"dropped_items": dropped,
		})
	remaining = maxf(remaining - FIXED_STEP, 0.0)
	record["respawn_remaining"] = remaining
	_set_respawn_remaining(actor, remaining)
	record["revision"] = int(record["revision"]) + 1
	if remaining <= 0.0:
		if actor.has_method("respawn"):
			actor.respawn(_spawn_position(record, actor))
		record["dead"] = false
		record["respawn_remaining"] = 0.0
		record["life_id"] = int(record["life_id"]) + 1
		record["guard"].reset(int(record["life_id"]))
		_melee.reset_player(record["id"], int(record["life_id"]))
		_touch_domain()
		_emit_event("player_respawned", record, {
			"life_id": int(record["life_id"]),
			"health": _actor_health(actor, "real_hp"),
		})

func _accepts_actions(record: Dictionary) -> bool:
	if not bool(record["online"]): return false
	if bool(record["extracted"]): return false
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
		"life_id": int(record.get("life_id", 1)),
	}
	event.merge(extra, true)
	_events.append(event)

func _touch_domain() -> void:
	_domain_revision += 1

func _sync_domain_revisions() -> void:
	var match_revision: int = int(_match.get_state().get("revision", 0))
	if match_revision != _seen_match_revision:
		_seen_match_revision = match_revision
		_touch_domain()
	var shot_revision: int = int(_shotgun.get_state().get("revision", 0))
	if shot_revision != _seen_shot_revision:
		_seen_shot_revision = shot_revision
		_touch_domain()
	var melee_revision: int = int(_melee.get_state().get("revision", 0))
	if melee_revision != _seen_melee_revision:
		_seen_melee_revision = melee_revision
		_touch_domain()
	if int(_items.revision) != _seen_item_revision:
		_seen_item_revision = int(_items.revision)
		_touch_domain()
	var extraction_revision: int = int(_extraction.get_state().get("revision", 0))
	if extraction_revision != _seen_extraction_revision:
		_seen_extraction_revision = extraction_revision
		_touch_domain()

func get_combat_state() -> Dictionary:
	var shotgun_state: Dictionary = _shotgun.get_state()
	var melee_state: Dictionary = _melee.get_state()
	var guards: Dictionary = {}
	for player_id: StringName in _players.keys():
		guards[String(player_id)] = _players[player_id]["guard"].get_state()
	return {
		# One monotonic checkpoint revision for the whole combat domain. Guard
		# drain between discrete changes still travels in the 20 Hz snapshots.
		"revision": _domain_revision,
		"server_tick": _tick,
		"projectiles": shotgun_state.get("projectiles", []),
		"events": shotgun_state.get("events", []),
		"shotgun_revision": int(shotgun_state.get("revision", 0)),
		"melee_events": melee_state.get("events", []),
		"melee_revision": int(melee_state.get("revision", 0)),
		"pending_swords": int(melee_state.get("pending_actions", 0)),
		"guards": guards,
		"items": _items.get_state(),
		"extraction": _extraction.get_state(),
		"match": _match.get_state(),
	}
