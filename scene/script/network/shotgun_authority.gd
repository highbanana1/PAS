extends RefCounted
## Host-only projectile simulation. No camera, visual bullet or client damage hooks.
const Receiver = preload("res://scene/script/combat/combat_receiver.gd")
const Context = preload("res://scene/script/combat/attack_context.gd")
const RADIUS := 2.5
const LIFETIME := 180
const COOLDOWN := 39
var _pellets: Array[Dictionary] = []
var _pending: Array[Dictionary] = []

## A completed evacuee leaves combat immediately, including shots submitted
## earlier in the same authority tick and pellets still in flight.
func cancel_player(player_id: StringName) -> void:
	var remaining_requests: Array[Dictionary] = []
	for request: Dictionary in _pending:
		if StringName(String(request.get("player_id", ""))) != player_id:
			remaining_requests.append(request)
	_pending = remaining_requests
	for index in range(_pellets.size() - 1, -1, -1):
		if StringName(String(_pellets[index].get("player_id", ""))) == player_id:
			_remove(index, "extracted")
var _next_fire: Dictionary = {}
var _events: Array[Dictionary] = []
var _shot_id: int = 0
var _event_id: int = 0
var _tick: int = 0
var _rng := RandomNumberGenerator.new()

func _init() -> void:
	_rng.randomize()

func request_fire(player_id: StringName, actor: Node, direction: Variant, tick: int) -> bool:
	if not actor is Node2D or actor.get("is_dead") == true:
		return false
	if not direction is Vector2 or not direction.is_finite():
		return false
	var direction_length_squared: float = direction.length_squared()
	if not is_finite(direction_length_squared) or direction_length_squared < 0.000001:
		return false
	if tick < int(_next_fire.get(player_id, -1)):
		return false
	_next_fire[player_id] = tick + COOLDOWN
	_pending.append({"player_id": String(player_id), "actor": actor, "direction": direction.normalized()})
	return true

func step(tick: int, players: Dictionary) -> void:
	_tick = tick
	for request: Dictionary in _pending:
		var actor: Node2D = request.actor
		if not is_instance_valid(actor) or actor.get("is_dead") == true \
				or bool(players.get(StringName(request.player_id), {}).get("extracted", false)):
			continue
		_shot_id += 1
		var first_pellet_index := _pellets.size()
		var pellets: Array[Dictionary] = []
		var direction: Vector2 = request.direction
		# Fixed host configuration; never accept client-supplied muzzle coordinates.
		var origin: Vector2 = actor.global_position + direction * 16.0
		var muzzle_hit := _sweep(actor, actor.global_position, direction * 16.0, players)
		for index in range(5):
			var angle := (_rng.randf_range(-0.5, 0.5) + _rng.randf_range(-0.5, 0.5)) * deg_to_rad(7.5)
			var heading := direction.rotated(angle)
			var speed := 700.0 * _rng.randf_range(0.92, 1.08)
			var pellet := {"shot_id": _shot_id, "pellet_id": index, "player_id": request.player_id,
				"position": origin, "origin": origin, "direction": heading, "velocity": heading * speed,
				"speed": speed, "spawn_tick": tick}
			_pellets.append(pellet)
			pellets.append(pellet.duplicate(true))
		_emit({"type": "shot_spawned", "shot_id": _shot_id, "pellet_id": -1, "pellets": pellets})
		# Sweep the short actor-to-muzzle segment too. Otherwise a player pressed
		# against a thin wall could create every pellet behind the obstruction.
		if not muzzle_hit.is_empty():
			for pellet_index in range(_pellets.size() - 1, first_pellet_index - 1, -1):
				_resolve_hit(pellet_index, muzzle_hit, players, actor)
	_pending.clear()
	for index in range(_pellets.size() - 1, -1, -1):
		var pellet: Dictionary = _pellets[index]
		var shooter_record: Dictionary = players.get(StringName(pellet.player_id), {})
		var shooter: Node = shooter_record.get("actor")
		if tick - int(pellet.spawn_tick) >= LIFETIME or not is_instance_valid(shooter):
			_remove(index, "expired")
			continue
		var velocity: Vector2 = pellet.velocity
		velocity.y += 35.0 / 60.0
		var motion := velocity / 60.0
		var hit := _sweep(shooter, pellet.position, motion, players)
		if not hit.is_empty():
			_resolve_hit(index, hit, players, shooter)
		else:
			pellet.position += motion
			pellet.velocity = velocity

func get_state() -> Dictionary:
	return {"revision": _event_id, "server_tick": _tick, "projectiles": _pellets.duplicate(true), "events": _events.duplicate(true)}

func _emit(event: Dictionary) -> void:
	_event_id += 1
	event["event_id"] = _event_id
	event["server_tick"] = _tick
	event["revision"] = _event_id
	_events.append(event)
	if _events.size() > 64:
		_events.pop_front()

func _remove(index: int, reason: String, extra: Dictionary = {}) -> void:
	var pellet: Dictionary = _pellets[index]
	var event := {"type": "pellet_removed", "shot_id": pellet.shot_id, "pellet_id": pellet.pellet_id, "reason": reason}
	event.merge(extra)
	_emit(event)
	_pellets.remove_at(index)

func _resolve_hit(index: int, hit: Dictionary, players: Dictionary, shooter: Node2D) -> void:
	var pellet: Dictionary = _pellets[index]
	var target: Object = hit.get("collider")
	var result := Context.Result.IGNORED
	var target_id := ""
	for player_id: StringName in players:
		if players[player_id].get("actor") == target \
				and not bool(players[player_id].get("extracted", false)):
			target_id = String(player_id)
			break
	if not target_id.is_empty() and target is Node2D:
		var target_record: Dictionary = players.get(StringName(target_id), {})
		var guard = target_record.get("guard")
		var blocked := false
		if guard != null and target_record.get("dead") != true:
			# Guard direction, resource and exhaustion are host state. The
			# target's client-local WeaponController never decides this block.
			var toward_attack: Vector2 = pellet.origin - (target as Node2D).global_position
			var block: Dictionary = guard.try_block(toward_attack, true)
			if bool(block.get("blocked", false)):
				blocked = true
				result = Context.Result.BLOCKED
				_emit({
					"type": "guard_blocked",
					"shot_id": pellet.shot_id,
					"pellet_id": pellet.pellet_id,
					"target_id": target_id,
					"guard": block,
					"result": result,
				})
		if not blocked:
			# Each pellet invokes damage independently, preserving health-cell
			# overflow. Guard already decided above, so this context is
			# unblockable and cannot charge the guard a second time.
			result = Receiver.deliver(target, Context.new(2.0, pellet.origin, shooter, false))
	_remove(index, "hit", {"target_id": target_id, "result": result})

func get_revision() -> int:
	return _event_id

func _sweep(shooter: Node2D, origin: Vector2, motion: Vector2, players: Dictionary) -> Dictionary:
	if not shooter.is_inside_tree():
		return {}
	var space := shooter.get_world_2d().direct_space_state
	var query := PhysicsShapeQueryParameters2D.new()
	var circle := CircleShape2D.new()
	circle.radius = RADIUS
	query.shape = circle
	query.collision_mask = 3
	query.transform = Transform2D(0.0, origin)
	var excluded: Array[RID] = []
	if shooter is CollisionObject2D:
		excluded.append(shooter.get_rid())
	query.exclude = excluded
	# cast_motion ignores initial overlap, so test it explicitly first.
	var overlaps := space.intersect_shape(query, 32)
	if not overlaps.is_empty():
		return _prefer_world(overlaps)
	query.motion = motion
	var fractions := space.cast_motion(query)
	if fractions.size() < 2 or fractions[0] >= 1.0:
		return {}
	query.motion = Vector2.ZERO
	query.transform.origin = origin + motion * minf(fractions[1] + 0.001, 1.0)
	overlaps = space.intersect_shape(query, 32)
	if not overlaps.is_empty():
		return _prefer_world(overlaps)
	# Collision is known even if floating point contact has no overlap: destroy,
	# never tunnel through a wall on an ambiguous contact.
	return {"collider": null}

func _prefer_world(hits: Array[Dictionary]) -> Dictionary:
	for hit: Dictionary in hits:
		var collider: Object = hit.get("collider")
		if collider is CollisionObject2D and collider.collision_layer & 1:
			return hit
	return hits[0]
