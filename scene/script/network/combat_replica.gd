extends RefCounted
## Full checkpoints with a tick/revision watermark; old packets cannot resurrect
## pellets, regress guard state or re-own items.
var _epoch: int = 0
var _tick: int = -1
var _revision: int = -1
var _state: Dictionary = {}
var _players: Dictionary = {}

func configure(epoch: int) -> void:
	_epoch = epoch
	_tick = -1
	_revision = -1
	_state = {}
	_players = {}

func apply_packet(packet: Dictionary) -> bool:
	if int(packet.get("match_epoch", -1)) != _epoch or not packet.get("combat") is Dictionary:
		return false
	var tick := int(packet.get("server_tick", -1))
	var state: Dictionary = packet.combat
	var revision := int(state.get("revision", -1))
	if tick < _tick or revision < _revision or (tick == _tick and revision <= _revision):
		return false
	if not state.get("projectiles") is Array or not state.get("events") is Array:
		return false
	_tick = tick
	_revision = revision
	_state = state.duplicate(true)
	_players = packet.get("players", {}).duplicate(true)
	return true

func get_state() -> Dictionary:
	return _state.duplicate(true)

func get_player(player_id: String) -> Dictionary:
	return _players.get(player_id, {}).duplicate(true)

func get_guard(player_id: StringName) -> Dictionary:
	var guards_variant: Variant = _state.get("guards", {})
	if not guards_variant is Dictionary:
		return {}
	var guard_variant: Variant = (guards_variant as Dictionary).get(String(player_id), {})
	return (guard_variant as Dictionary).duplicate(true) if guard_variant is Dictionary else {}

func get_guards() -> Dictionary:
	var guards_variant: Variant = _state.get("guards", {})
	return (guards_variant as Dictionary).duplicate(true) if guards_variant is Dictionary else {}

func get_items() -> Dictionary:
	var items_variant: Variant = _state.get("items", {})
	return (items_variant as Dictionary).duplicate(true) if items_variant is Dictionary else {}

func get_extraction() -> Dictionary:
	var value: Variant = _state.get("extraction", {})
	return (value as Dictionary).duplicate(true) if value is Dictionary else {}

func get_match() -> Dictionary:
	var value: Variant = _state.get("match", {})
	return (value as Dictionary).duplicate(true) if value is Dictionary else {}

func get_item(item_id: int) -> Dictionary:
	var items_variant: Variant = get_items().get("items", {})
	if not items_variant is Dictionary:
		return {}
	var item_variant: Variant = (items_variant as Dictionary).get(str(item_id), {})
	return (item_variant as Dictionary).duplicate(true) if item_variant is Dictionary else {}

func get_item_inventory(player_id: StringName) -> Array:
	var result: Array = []
	var items_variant: Variant = get_items().get("items", {})
	if not items_variant is Dictionary:
		return result
	for key: Variant in (items_variant as Dictionary).keys():
		var item_variant: Variant = items_variant[key]
		if not item_variant is Dictionary:
			continue
		var item: Dictionary = item_variant
		if String(item.get("owner", "")) != String(player_id):
			continue
		if String(item.get("state", "carried")) != "carried":
			continue
		result.append(item.duplicate(true))
	result.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
		return int(a.get("item_id", 0)) < int(b.get("item_id", 0)))
	return result

func get_world_items() -> Array:
	var result: Array = []
	var items_variant: Variant = get_items().get("items", {})
	if not items_variant is Dictionary:
		return result
	for key: Variant in (items_variant as Dictionary).keys():
		var item_variant: Variant = items_variant[key]
		if not item_variant is Dictionary:
			continue
		var item: Dictionary = item_variant
		if String(item.get("state", "")) == "world":
			result.append(item.duplicate(true))
	result.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
		return int(a.get("item_id", 0)) < int(b.get("item_id", 0)))
	return result

func get_melee_events() -> Array:
	var events_variant: Variant = _state.get("melee_events", [])
	return (events_variant as Array).duplicate(true) if events_variant is Array else []

func get_life_id(player_id: StringName) -> int:
	var player: Dictionary = get_player(String(player_id))
	return int(player.get("life_id", 0))

func clear() -> void:
	_state = {}
	_players = {}
