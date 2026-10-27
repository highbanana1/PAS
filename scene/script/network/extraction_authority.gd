extends RefCounted
## Host-only star and extraction authority for PAS Ticket05.
##
## The module is deliberately pure data: Vector2 positions, String/StringName
## ids, integer ticks and Dictionaries only. It has no Node, Resource, RID,
## scene or instance-id dependency and never mutates the player records given
## to step()/reconcile().
##
## MatchAuthority calls step(new_tick, players) before movement and damage for
## a tick, so an alive owner at a point at the deadline extracts before damage
## on that same tick resolves. reconcile(players) is called after movement and
## combat and only cancels invalid bindings; it never grants an extraction.
##
## Time is integer ticks at 60 Hz. A 30 second extraction is exactly 1800
## ticks, avoiding accumulated floating point error.

const TICKS_PER_SECOND: int = 60
const DEFAULT_DURATION_TICKS: int = 1800
const PICKUP_RADIUS: float = 40.0
const MAX_EVENTS: int = 128

const STATE_FREE: String = "FREE"
const STATE_CARRIED: String = "CARRIED"
const STATE_BOUND: String = "BOUND"
const STATE_CONSUMED: String = "CONSUMED"

const RESULT_EXTRACTED: String = "extracted"

const EVENT_STAR_REGISTERED: String = "STAR_REGISTERED"
const EVENT_POINT_REGISTERED: String = "POINT_REGISTERED"
const EVENT_PICKED_UP: String = "PICKED_UP"
const EVENT_DELIVERED: String = "DELIVERED"
const EVENT_CANCELLED: String = "CANCELLED"
const EVENT_DROPPED: String = "DROPPED"
const EVENT_EXTRACTED: String = "EXTRACTED"

var _duration_ticks: int = DEFAULT_DURATION_TICKS
var _revision: int = 0
var _server_tick: int = 0
var _last_step_tick: int = -1
var _has_stepped: bool = false
var _stars: Dictionary = {}
var _points: Dictionary = {}
var _results: Dictionary = {}
var _events: Array[Dictionary] = []
var _next_event_id: int = 1

## Allowed only before the first star or point is registered. Rejects
## non-finite and non-positive durations and leaves the old duration intact on
## failure. Positive durations that round below one tick are clamped to one.
func configure(extraction_seconds: float = 30.0) -> bool:
	if not _stars.is_empty() or not _points.is_empty():
		return false
	if not is_finite(extraction_seconds) or extraction_seconds <= 0.0:
		return false
	var ticks: int = roundi(extraction_seconds * float(TICKS_PER_SECOND))
	if ticks < 1:
		ticks = 1
	_duration_ticks = ticks
	return true

func register_star(id: StringName, position: Vector2) -> bool:
	if String(id).is_empty() or not position.is_finite():
		return false
	if _stars.has(id):
		return false
	var star: Dictionary = {
		"star_id": String(id),
		"state": STATE_FREE,
		"position": position,
		"owner": "",
		"point_id": "",
		"deadline_tick": 0,
		"revision": 1,
		"owner_life": 0,
		"has_owner_life": false,
		"last_owner_position": position,
	}
	_stars[id] = star
	_revision += 1
	_emit_event(EVENT_STAR_REGISTERED, String(id), "", "", _server_tick)
	return true

func register_point(id: StringName, position: Vector2, radius: float = 48.0) -> bool:
	if String(id).is_empty() or not position.is_finite():
		return false
	if not is_finite(radius) or radius <= 0.0:
		return false
	if _points.has(id):
		return false
	_points[id] = {
		"point_id": String(id),
		"position": position,
		"radius": radius,
	}
	_revision += 1
	_emit_event(EVENT_POINT_REGISTERED, "", "", String(id), _server_tick)
	return true

## Atomic pickup: every condition is checked before any field changes. A
## player may own at most one CARRIED or BOUND star, and BOUND stars are never
## freely pickable.
func request_pickup(player_id: StringName, star_id: StringName, expected_revision: int,
		player: Dictionary) -> bool:
	var player_key: String = String(player_id)
	if player_key.is_empty():
		return false
	if not _stars.has(star_id):
		return false
	var star: Dictionary = _stars[star_id]
	if String(star["state"]) != STATE_FREE:
		return false
	if int(star["revision"]) != expected_revision:
		return false
	var snapshot: Dictionary = _read_player(player)
	if snapshot.is_empty():
		return false
	var alive: bool = snapshot["alive"]
	var spectating: bool = snapshot["spectating"]
	if not alive or spectating:
		return false
	if _has_owned_active_star(player_key):
		return false
	var player_position: Vector2 = snapshot["position"]
	var star_position: Vector2 = star["position"]
	if player_position.distance_squared_to(star_position) > PICKUP_RADIUS * PICKUP_RADIUS:
		return false
	var life_id: int = snapshot["life_id"]
	star["state"] = STATE_CARRIED
	star["owner"] = player_key
	star["position"] = player_position
	star["last_owner_position"] = player_position
	star["point_id"] = ""
	star["deadline_tick"] = 0
	star["owner_life"] = life_id
	star["has_owner_life"] = true
	_bump_star(star)
	_emit_event(EVENT_PICKED_UP, String(star["star_id"]), player_key, "", _server_tick)
	return true

## Atomic delivery of the player's one CARRIED star to an unoccupied point.
## The star's own revision is the compare-and-swap value. Occupancy is derived
## only from BOUND stars, so a cancelled or dropped binding frees its point.
func request_delivery(player_id: StringName, point_id: StringName, expected_revision: int,
		player: Dictionary, tick: int) -> bool:
	var player_key: String = String(player_id)
	var point_key: String = String(point_id)
	if player_key.is_empty() or point_key.is_empty() or tick < 0:
		return false
	var snapshot: Dictionary = _read_player(player)
	if snapshot.is_empty():
		return false
	var alive: bool = snapshot["alive"]
	var spectating: bool = snapshot["spectating"]
	if not alive or spectating:
		return false
	var star: Dictionary = _find_carried_star(player_key)
	if star.is_empty():
		return false
	if int(star["revision"]) != expected_revision:
		return false
	var point: Dictionary = _lookup_point(point_key)
	if point.is_empty():
		return false
	if not _bound_star_at(point_key).is_empty():
		return false
	var player_position: Vector2 = snapshot["position"]
	var point_position: Vector2 = point["position"]
	var radius: float = point["radius"]
	if player_position.distance_squared_to(point_position) > radius * radius:
		return false
	var life_id: int = snapshot["life_id"]
	star["state"] = STATE_BOUND
	star["owner"] = player_key
	star["point_id"] = point_key
	star["deadline_tick"] = tick + _duration_ticks
	star["owner_life"] = life_id
	star["has_owner_life"] = true
	star["position"] = point_position
	star["last_owner_position"] = player_position
	_bump_star(star)
	_emit_event(EVENT_DELIVERED, String(star["star_id"]), player_key, point_key, tick)
	return true

## Monotonic extraction pass. Invalid bindings are reconciled first with the
## supplied pre-movement player snapshot, then every still-valid BOUND star
## whose integer deadline has arrived is consumed. Duplicate or older ticks
## still reconcile but cannot consume anything, so a success is never granted
## twice and time never moves backwards.
func step(tick: int, players: Dictionary) -> Array[StringName]:
	var extracted: Array[StringName] = []
	if tick < 0:
		return extracted
	var advancing: bool = not _has_stepped or tick > _last_step_tick
	if advancing:
		_has_stepped = true
		_last_step_tick = tick
		if tick > _server_tick:
			_server_tick = tick
	reconcile(players)
	if not advancing:
		return extracted
	for key: StringName in _stars.keys():
		var star: Dictionary = _stars[key]
		if String(star["state"]) != STATE_BOUND:
			continue
		if int(star["deadline_tick"]) > tick:
			continue
		var owner_id: String = String(star["owner"])
		if owner_id.is_empty():
			continue
		var snapshot: Dictionary = _read_player(_find_player(players, owner_id))
		if snapshot.is_empty():
			continue
		var alive: bool = snapshot["alive"]
		var spectating: bool = snapshot["spectating"]
		if not alive or spectating:
			continue
		if bool(star["has_owner_life"]) and int(star["owner_life"]) != int(snapshot["life_id"]):
			continue
		star["state"] = STATE_CONSUMED
		_bump_star(star)
		_results[owner_id] = RESULT_EXTRACTED
		_emit_event(EVENT_EXTRACTED, String(star["star_id"]), owner_id,
			String(star["point_id"]), tick)
		extracted.append(StringName(owner_id))
	return extracted

## Never completes an extraction. Death, spectating, a missing player, a
## changed life, or an alive owner walking out of the point all cancel the
## binding. Leave returns BOUND to CARRIED for the same owner; death, a life
## mismatch, spectating or a missing player drops the star FREE at the death
## or last known owner position. CARRIED positions may track their owner here
## without a revision bump because motion is not a discrete state change.
func reconcile(players: Dictionary) -> void:
	for key: StringName in _stars.keys():
		var star: Dictionary = _stars[key]
		var state: String = String(star["state"])
		if state != STATE_CARRIED and state != STATE_BOUND:
			continue
		var owner_id: String = String(star["owner"])
		var last_position: Vector2 = star["last_owner_position"]
		if not last_position.is_finite():
			last_position = Vector2.ZERO
		if owner_id.is_empty():
			_drop_star(star, last_position)
			continue
		var snapshot: Dictionary = _read_player(_find_player(players, owner_id))
		if snapshot.is_empty():
			_drop_star(star, last_position)
			continue
		var owner_position: Vector2 = snapshot["position"]
		var alive: bool = snapshot["alive"]
		var spectating: bool = snapshot["spectating"]
		var life_id: int = snapshot["life_id"]
		if not alive or spectating:
			_drop_star(star, owner_position)
			continue
		if bool(star["has_owner_life"]) and int(star["owner_life"]) != life_id:
			_drop_star(star, owner_position)
			continue
		if state == STATE_CARRIED:
			star["position"] = owner_position
			star["last_owner_position"] = owner_position
			continue
		# BOUND: the star remains at the point but remember where its owner was
		# so a later disconnect can release it at the last authoritative spot.
		star["last_owner_position"] = owner_position
		var point_id: String = String(star["point_id"])
		var point: Dictionary = _lookup_point(point_id)
		if point.is_empty():
			_cancel_binding(star, owner_position)
			continue
		var point_position: Vector2 = point["position"]
		var radius: float = point["radius"]
		if owner_position.distance_squared_to(point_position) > radius * radius:
			_cancel_binding(star, owner_position)

## Idempotent disconnect/cleanup release. CARRIED and BOUND stars become FREE
## at the supplied last position; CONSUMED stars and results are untouched.
func release_player(player_id: StringName, position: Vector2) -> void:
	var player_key: String = String(player_id)
	if player_key.is_empty():
		return
	for key: StringName in _stars.keys():
		var star: Dictionary = _stars[key]
		if String(star["owner"]) != player_key:
			continue
		var state: String = String(star["state"])
		if state != STATE_CARRIED and state != STATE_BOUND:
			continue
		var drop_position: Vector2 = position
		if not drop_position.is_finite():
			drop_position = star["last_owner_position"]
		_drop_star(star, drop_position)

## Fully isolated snapshot. Nested star/point/result/event dictionaries and the
## event array are rebuilt or duplicated; a caller may mutate the result in any
## way without changing authority state.
func get_state() -> Dictionary:
	var stars: Dictionary = {}
	for key: StringName in _stars.keys():
		var star: Dictionary = _stars[key]
		var star_id: String = String(star["star_id"])
		var star_position: Vector2 = star["position"]
		stars[star_id] = {
			"star_id": star_id,
			"state": String(star["state"]),
			"position": star_position,
			"owner": String(star["owner"]),
			"point_id": String(star["point_id"]),
			"deadline_tick": int(star["deadline_tick"]),
			"revision": int(star["revision"]),
			"owner_life": int(star["owner_life"]),
		}
	var points: Dictionary = {}
	for key: StringName in _points.keys():
		var point: Dictionary = _points[key]
		var point_id: String = String(point["point_id"])
		var point_position: Vector2 = point["position"]
		points[point_id] = {
			"point_id": point_id,
			"position": point_position,
			"radius": float(point["radius"]),
			"occupant": _point_occupant(point_id),
		}
	return {
		"revision": _revision,
		"server_tick": _server_tick,
		"duration_ticks": _duration_ticks,
		"stars": stars,
		"points": points,
		"results": _results.duplicate(true),
		"events": _events.duplicate(true),
	}

## Player dictionaries are guest/command data. Read only the documented keys,
## require exact primitive types, and return an empty Dictionary on malformed
## input so every command can fail without touching state.
func _read_player(value: Variant) -> Dictionary:
	if typeof(value) != TYPE_DICTIONARY:
		return {}
	var source: Dictionary = value
	if not source.has("position") or not source.has("alive") \
			or not source.has("spectating") or not source.has("life_id"):
		return {}
	var raw_position: Variant = source["position"]
	var raw_alive: Variant = source["alive"]
	var raw_spectating: Variant = source["spectating"]
	var raw_life: Variant = source["life_id"]
	if typeof(raw_position) != TYPE_VECTOR2:
		return {}
	if typeof(raw_alive) != TYPE_BOOL or typeof(raw_spectating) != TYPE_BOOL:
		return {}
	if typeof(raw_life) != TYPE_INT:
		return {}
	var position: Vector2 = raw_position
	if not position.is_finite():
		return {}
	var alive: bool = raw_alive
	var spectating: bool = raw_spectating
	var life_id: int = raw_life
	return {
		"position": position,
		"alive": alive,
		"spectating": spectating,
		"life_id": life_id,
	}

## Accept both String and StringName player keys without trusting either.
func _find_player(players: Dictionary, player_id: String) -> Variant:
	if players.has(player_id):
		return players[player_id]
	var key: StringName = StringName(player_id)
	if players.has(key):
		return players[key]
	return null

func _lookup_point(point_id: String) -> Dictionary:
	if point_id.is_empty():
		return {}
	var key: StringName = StringName(point_id)
	if _points.has(key):
		return _points[key]
	return {}

func _find_carried_star(player_id: String) -> Dictionary:
	for key: StringName in _stars.keys():
		var star: Dictionary = _stars[key]
		if String(star["owner"]) != player_id:
			continue
		if String(star["state"]) == STATE_CARRIED:
			return star
	return {}

func _has_owned_active_star(player_id: String) -> bool:
	for key: StringName in _stars.keys():
		var star: Dictionary = _stars[key]
		if String(star["owner"]) != player_id:
			continue
		var state: String = String(star["state"])
		if state == STATE_CARRIED or state == STATE_BOUND:
			return true
	return false

func _bound_star_at(point_id: String) -> Dictionary:
	for key: StringName in _stars.keys():
		var star: Dictionary = _stars[key]
		if String(star["state"]) != STATE_BOUND:
			continue
		if String(star["point_id"]) == point_id:
			return star
	return {}

func _point_occupant(point_id: String) -> String:
	var star: Dictionary = _bound_star_at(point_id)
	if star.is_empty():
		return ""
	return String(star["owner"])

func _cancel_binding(star: Dictionary, position: Vector2) -> void:
	var old_point: String = String(star["point_id"])
	star["state"] = STATE_CARRIED
	star["point_id"] = ""
	star["deadline_tick"] = 0
	star["position"] = position
	star["last_owner_position"] = position
	_bump_star(star)
	_emit_event(EVENT_CANCELLED, String(star["star_id"]), String(star["owner"]),
		old_point, _server_tick)

func _drop_star(star: Dictionary, position: Vector2) -> void:
	var old_owner: String = String(star["owner"])
	var old_point: String = String(star["point_id"])
	var drop_position: Vector2 = position
	if not drop_position.is_finite():
		drop_position = star["last_owner_position"]
	if not drop_position.is_finite():
		drop_position = star["position"]
	if not drop_position.is_finite():
		drop_position = Vector2.ZERO
	star["state"] = STATE_FREE
	star["position"] = drop_position
	star["owner"] = ""
	star["point_id"] = ""
	star["deadline_tick"] = 0
	star["owner_life"] = 0
	star["has_owner_life"] = false
	star["last_owner_position"] = drop_position
	_bump_star(star)
	_emit_event(EVENT_DROPPED, String(star["star_id"]), old_owner, old_point, _server_tick)

func _bump_star(star: Dictionary) -> void:
	star["revision"] = int(star["revision"]) + 1
	_revision += 1

func _emit_event(event_type: String, star_id: String, player_id: String,
		point_id: String, tick: int) -> void:
	var event: Dictionary = {
		"event_id": _next_event_id,
		"type": event_type,
		"star_id": star_id,
		"player_id": player_id,
		"point_id": point_id,
		"tick": tick,
	}
	_next_event_id += 1
	_events.append(event)
	while _events.size() > MAX_EVENTS:
		_events.pop_front()
