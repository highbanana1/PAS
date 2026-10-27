extends RefCounted
## Host-owned stable item registry. Only id, type, numeric reserve/capacity,
## owner, state, JSON-safe position and revision cross the network. No Node,
## Resource, WeakRef, texture or RID enters the checkpoint.
##
## Every item mutation is an atomic host decision: owner/alive/type/value and
## expected_revision are checked here, then the actor and item are modified and
## the item revision is advanced. A stale expected_revision loses cleanly.

const TYPE_HEALTH: StringName = &"health"
const TYPE_JUMP: StringName = &"jump"
const PICKUP_DISTANCE: float = 40.0
const MAX_SLOTS: int = 3
const MAX_EVENTS: int = 128
const EPSILON: float = 0.000001

var revision: int = 0
var _next_item_id: int = 0
var _items: Dictionary = {}
var _dropped_life: Dictionary = {}
var _events: Array[Dictionary] = []
var _event_id: int = 0

func grant(player_id: StringName, item_type: Variant, remaining: float, capacity: float) -> int:
	var type_name := StringName(String(item_type))
	if type_name != TYPE_HEALTH and type_name != TYPE_JUMP:
		return -1
	if not is_finite(remaining) or not is_finite(capacity) or remaining <= 0.0 or capacity <= 0.0:
		return -1
	if remaining > capacity + EPSILON:
		return -1
	if _carried_count(player_id) >= MAX_SLOTS:
		return -1
	_next_item_id += 1
	var item_id := _next_item_id
	_items[item_id] = {
		"item_id": item_id,
		"type": String(type_name),
		"remaining": remaining,
		"capacity": capacity,
		"owner": String(player_id),
		"revision": 1,
		"position": Vector2.ZERO,
		"state": "carried",
	}
	revision += 1
	_emit({"type": "item_granted", "item_id": item_id, "item_type": String(type_name),
		"owner": String(player_id), "remaining": remaining, "capacity": capacity})
	return item_id

func get_state() -> Dictionary:
	var items: Dictionary = {}
	for item_id: int in _items.keys():
		items[str(item_id)] = _public(_items[item_id])
	return {"revision": revision, "items": items}

func get_item(item_id: int) -> Dictionary:
	if not _items.has(item_id):
		return {}
	return _public(_items[item_id])

func get_inventory(player_id: StringName) -> Array:
	var result: Array = []
	for item_id: int in _items.keys():
		var item: Dictionary = _items[item_id]
		if String(item.owner) == String(player_id) and String(item.state) == "carried":
			result.append(_public(item))
	result.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
		return int(a.item_id) < int(b.item_id))
	return result

func get_world_items() -> Array:
	var result: Array = []
	for item_id: int in _items.keys():
		var item: Dictionary = _items[item_id]
		if String(item.state) == "world":
			result.append(_public(item))
	result.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
		return int(a.item_id) < int(b.item_id))
	return result

## Death drop is keyed by (player, life). Repeating death calls or later
## disconnect cleanup for the same life cannot create duplicate items.
func drop_inventory(player_id: StringName, life_id: int, at: Vector2) -> Array:
	if int(_dropped_life.get(player_id, -1)) >= life_id:
		return []
	_dropped_life[player_id] = life_id
	var dropped: Array = []
	var position: Vector2 = at if at.is_finite() else Vector2.ZERO
	for item_id: int in _items.keys():
		var item: Dictionary = _items[item_id]
		if String(item.owner) != String(player_id) or String(item.state) != "carried":
			continue
		item["owner"] = ""
		item["state"] = "world"
		item["position"] = position
		item["revision"] = int(item.revision) + 1
		revision += 1
		dropped.append(item_id)
		_emit({"type": "item_dropped", "item_id": item_id, "owner": String(player_id),
			"revision": int(item.revision)})
	return dropped

## Returns {accepted, reason, item}. The first valid command for an unowned
## world item wins; later requests see the owner/revision and cannot move or
## duplicate it. The winner must also have a free backpack slot.
func request_pickup(player_id: StringName, item_id: int, actor_position: Vector2,
		alive: bool, expected_revision: int) -> Dictionary:
	if not alive or not actor_position.is_finite():
		return {"accepted": false, "reason": "not_alive"}
	if not _items.has(item_id):
		return {"accepted": false, "reason": "unknown_item"}
	var item: Dictionary = _items[item_id]
	if expected_revision <= 0 or expected_revision != int(item.revision):
		return {"accepted": false, "reason": "stale_revision"}
	if String(item.owner) != "" or String(item.state) != "world":
		return {"accepted": false, "reason": "already_owned"}
	if _carried_count(player_id) >= MAX_SLOTS:
		return {"accepted": false, "reason": "inventory_full"}
	var at: Vector2 = item.position
	if at.distance_to(actor_position) > PICKUP_DISTANCE:
		return {"accepted": false, "reason": "out_of_range"}
	item["owner"] = String(player_id)
	item["state"] = "carried"
	item["revision"] = int(item.revision) + 1
	revision += 1
	var item_copy := _public(item)
	_emit({"type": "item_picked_up", "item_id": item_id, "owner": String(player_id),
		"revision": int(item.revision)})
	return {"accepted": true, "reason": "", "item": item_copy}

## Host-owned use. Mode is decided by item type:
##   health + expand: full reserve expands exactly one health cell
##   health + heal:   requested amount is clamped/consumed by the host
##   jump + jump:     one reserve unit grants one temporary air jump
## Returns {accepted, reason, item, consumed}. The expected_revision CAS is
## checked before any actor or item mutation.
func request_use(player_id: StringName, item_id: int, expected_revision: int,
		mode: String, amount: float, actor: Node) -> Dictionary:
	if not is_instance_valid(actor) or actor.get("is_dead") == true:
		return {"accepted": false, "reason": "not_alive"}
	if not _items.has(item_id):
		return {"accepted": false, "reason": "unknown_item"}
	var item: Dictionary = _items[item_id]
	if expected_revision <= 0 or expected_revision != int(item.revision):
		return {"accepted": false, "reason": "stale_revision"}
	if String(item.owner) != String(player_id) or String(item.state) != "carried":
		return {"accepted": false, "reason": "not_owned"}
	if float(item.remaining) <= 0.0:
		return {"accepted": false, "reason": "empty"}
	var item_type := String(item.type)
	var consumed := 0.0
	var accepted := false
	var reason := ""
	match item_type:
		"health":
			if mode == "expand":
				accepted = _use_health_expand(actor, item)
				if accepted:
					consumed = float(item.remaining)
				else:
					reason = "cannot_expand"
			elif mode == "heal":
				if not is_finite(amount) or amount <= 0.0:
					reason = "invalid_amount"
				else:
					consumed = _use_health_heal(actor, item, amount)
					accepted = consumed > 0.0
					if not accepted:
						reason = "no_effect"
			else:
				reason = "invalid_mode"
		"jump":
			if mode != "jump":
				reason = "invalid_mode"
			else:
				accepted = _use_jump(actor, item)
				if accepted:
					consumed = 1.0
				else:
					reason = "no_bonus"
		_:
			reason = "invalid_type"
	if not accepted:
		return {"accepted": false, "reason": reason}
	item["remaining"] = maxf(float(item.remaining) - consumed, 0.0)
	item["revision"] = int(item.revision) + 1
	revision += 1
	var result_item := _public(item)
	_emit({"type": "item_used", "item_id": item_id, "owner": String(player_id),
		"mode": mode, "consumed": consumed, "revision": int(item.revision)})
	if float(item.remaining) <= EPSILON:
		_items.erase(item_id)
		_emit({"type": "item_consumed", "item_id": item_id, "owner": String(player_id),
			"revision": int(item.revision)})
	return {"accepted": true, "reason": "", "item": result_item, "consumed": consumed}

func get_events() -> Array:
	return _events.duplicate(true)

func _use_health_expand(actor: Node, item: Dictionary) -> bool:
	var remaining := float(item.remaining)
	var capacity := float(item.capacity)
	if not is_equal_approx(remaining, capacity):
		return false
	var cell_value: Variant = actor.get("health_per_cell")
	var max_cells_value: Variant = actor.get("MAX_HEALTH_CELLS")
	var maximum_value: Variant = actor.get("max_hp")
	var current_value: Variant = actor.get("real_hp")
	if not (cell_value is float or cell_value is int):
		return false
	if not (max_cells_value is float or max_cells_value is int):
		return false
	if not (maximum_value is float or maximum_value is int):
		return false
	if not (current_value is float or current_value is int):
		return false
	var cell := float(cell_value)
	var max_cells := int(max_cells_value)
	var maximum := float(maximum_value)
	var current := float(current_value)
	if not is_finite(cell) or cell <= 0.0 or max_cells <= 0:
		return false
	if maximum + cell > cell * float(max_cells) + EPSILON:
		return false
	actor.set("max_hp", maximum + cell)
	actor.set("real_hp", minf(current + cell, float(actor.get("max_hp"))))
	return true

func _use_health_heal(actor: Node, item: Dictionary, amount: float) -> float:
	var health: Variant = actor.get_health_component() if actor.has_method("get_health_component") else null
	if not is_instance_valid(health) or not health.has_method("heal"):
		return 0.0
	var request := minf(amount, float(item.remaining))
	return float(health.heal(request))

func _use_jump(actor: Node, item: Dictionary) -> bool:
	if float(item.remaining) < 1.0:
		return false
	if not actor.has_method("get_motor"):
		return false
	var motor: Variant = actor.get_motor()
	if not is_instance_valid(motor) or not motor.has_method("grant_extra_air_jump"):
		return false
	return bool(motor.grant_extra_air_jump())

func _carried_count(player_id: StringName) -> int:
	var count := 0
	for item_id: int in _items.keys():
		var item: Dictionary = _items[item_id]
		if String(item.owner) == String(player_id) and String(item.state) == "carried":
			count += 1
	return count

func _public(item: Dictionary) -> Dictionary:
	var position: Vector2 = item.position if item.position is Vector2 else Vector2.ZERO
	return {
		"item_id": int(item.item_id),
		"type": String(item.type),
		"remaining": float(item.remaining),
		"capacity": float(item.capacity),
		"owner": String(item.owner),
		"revision": int(item.revision),
		"state": String(item.state),
		"position": {"x": position.x, "y": position.y},
	}

func _emit(event: Dictionary) -> void:
	_event_id += 1
	event["event_id"] = _event_id
	_events.append(event)
	if _events.size() > MAX_EVENTS:
		_events.pop_front()
