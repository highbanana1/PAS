extends Node
## Local key timing only. Offline it drives the ordered inventory directly. With
## a bound MatchNetworkBridge it still reads the same keys, but pickup/use are
## submitted as item intents carrying the stable item id and expected revision.
var actor: Node2D
var items: Node
@export_range(0.1, 2.0, 0.05) var hold_threshold: float = 0.3
var held: bool = false
var _elapsed: float = 0.0
var _held_slot: int = -1
var _held_item: RefCounted
var _held_item_id: int = 0

var _intent_bridge: Node = null
var _intent_player_id: StringName = &""
var _pending_heal: float = 0.0
var _last_heal_revision: int = -1
var _heal_retry_wait: float = 0.0
var _auto_pickup_wait: float = 0.0

const HEAL_CHUNK: float = 0.2
const HEAL_RETRY_SECONDS: float = 0.5
const NETWORK_PICKUP_DISTANCE: float = 40.0

func configure(owner_actor: Node2D, inventory: Node) -> void:
	actor = owner_actor; items = inventory
	actor.character_died.connect(reset_state)
	actor.respawned.connect(reset_state)
	actor.get_weapon_controller().weapon_changed.connect(_on_weapon_changed)
func enabled() -> bool:
	if not is_instance_valid(actor) or actor.get("is_dead") == true \
			or actor.get("is_locally_controlled") != true:
		return false
	if actor.get("network_authority") == true:
		return uses_network_intents()
	return true
func bind_network_intents(bridge: Node, player_id: StringName) -> bool:
	if not is_instance_valid(bridge) or player_id == &"":
		return false
	_intent_bridge = bridge
	_intent_player_id = player_id
	_pending_heal = 0.0
	_last_heal_revision = -1
	_heal_retry_wait = 0.0
	_auto_pickup_wait = 0.0
	return true
func clear_network_intents() -> void:
	_intent_bridge = null
	_intent_player_id = &""
	_pending_heal = 0.0
	_last_heal_revision = -1
	_heal_retry_wait = 0.0
	_auto_pickup_wait = 0.0
func uses_network_intents() -> bool:
	return is_instance_valid(_intent_bridge) and _intent_player_id != &""
func reset_state() -> void:
	held = false; _elapsed = 0.0; _held_slot = -1; _held_item = null
	_held_item_id = 0
	_pending_heal = 0.0
	_last_heal_revision = -1
	_heal_retry_wait = 0.0
	if is_instance_valid(items): items.cancel_use()
func _on_weapon_changed(_id: int) -> void:
	reset_state(); items.deselect_item()
func _is_weapon_event(event: InputEvent) -> bool:
	return event.is_action_pressed("weapon_slot_1") or event.is_action_pressed("weapon_slot_2") or event.is_action_pressed("weapon_next") or event.is_action_pressed("weapon_previous")
func _input(event: InputEvent) -> void:
	if enabled() and _is_weapon_event(event): _on_weapon_changed(0)
func _unhandled_input(event: InputEvent) -> void:
	if handle_event(event): get_viewport().set_input_as_handled()
func handle_event(event: InputEvent) -> bool:
	if not enabled(): return false
	if event is InputEventKey and event.echo: return false
	if _is_weapon_event(event): _on_weapon_changed(0); return false
	for slot in range(3):
		var action := "item_select_%d" % (slot + 1)
		if event.is_action_pressed(action):
			if not held or _held_slot != slot:
				reset_state(); items.select_item(slot)
				held = true; _held_slot = slot; _held_item = items.current_item()
				_held_item_id = int(_held_item.item_id) if _held_item != null else 0
			return true
		if event.is_action_released(action) and _held_slot == slot:
			reset_state(); return true
	if event.is_action_pressed("item_use") and items.selected:
		if uses_network_intents():
			_submit_use_selected()
			reset_state()
		else:
			if items.use_selected(): reset_state()
		return true
	if event.is_action_pressed("item_auto_pickup_toggle"):
		items.toggle_auto_pickup(); return true
	if event.is_action_pressed("item_pickup"):
		if uses_network_intents(): return _submit_pickup_nearest()
		items.pick_up_nearest(); return true
	return false
func _process(delta: float) -> void:
	tick(delta)
func tick(delta: float) -> void:
	if not enabled(): reset_state(); return
	if uses_network_intents():
		_tick_network(delta)
		return
	items.tick_auto_pickup(delta)
	if not held or not is_finite(delta) or delta <= 0.0: return
	if not _held_item_matches():
		reset_state(); return
	var previous := _elapsed; _elapsed += delta
	var active_time := maxf(_elapsed - hold_threshold, 0.0) - maxf(previous - hold_threshold, 0.0)
	if active_time > 0.0:
		items.begin_continuous_use(); items.tick_continuous_use(active_time)

func _tick_network(delta: float) -> void:
	_tick_network_auto_pickup(delta)
	if not held or not is_finite(delta) or delta <= 0.0: return
	if not _held_item_matches():
		reset_state(); return
	var current: RefCounted = items.current_item()
	_held_item = current
	if current == null or current.kind != &"health":
		return
	var previous := _elapsed; _elapsed += delta
	var active_time := maxf(_elapsed - hold_threshold, 0.0) - maxf(previous - hold_threshold, 0.0)
	if active_time > 0.0:
		_pending_heal += active_time
	if _pending_heal < HEAL_CHUNK:
		return
	# Send one authoritative heal chunk per observed item revision. Waiting for
	# the host's new revision prevents a burst of stale expected_revision
	# commands while still consuming reserve. A no-effect rejection does not
	# advance revision, so a bounded retry lets healing resume after damage.
	var revision := int(current.revision)
	if revision <= 0:
		return
	if revision == _last_heal_revision:
		_heal_retry_wait += delta
		if _heal_retry_wait < HEAL_RETRY_SECONDS:
			return
	else:
		_heal_retry_wait = 0.0
	var amount := float(current.capacity) * HEAL_CHUNK / maxf(float(items.use_duration), 0.1)
	if _intent_bridge.submit_use_item(int(current.item_id), "heal", revision, amount) >= 0:
		_last_heal_revision = revision
		_heal_retry_wait = 0.0
		_pending_heal = maxf(_pending_heal - HEAL_CHUNK, 0.0)

func _held_item_matches() -> bool:
	if not held or items.selected_index != _held_slot:
		return false
	var current: RefCounted = items.current_item()
	if current == null:
		return false
	if uses_network_intents():
		return int(current.item_id) > 0 and int(current.item_id) == _held_item_id
	return current == _held_item

func _submit_use_selected() -> bool:
	var current: RefCounted = items.current_item()
	if current == null or current.item_id <= 0:
		return false
	var mode := "jump" if current.kind == &"jump" else "expand"
	return _intent_bridge.submit_use_item(
		int(current.item_id), mode, int(current.revision), 0.0) >= 0

func _submit_pickup_nearest() -> bool:
	var item := _nearest_world_item()
	if item.is_empty():
		return false
	return _intent_bridge.submit_pickup(
		int(item.get("item_id", -1)), int(item.get("revision", -1))) >= 0

func _tick_network_auto_pickup(delta: float) -> void:
	if not items.auto_pickup_enabled or items.items.size() >= items.slot_count:
		return
	_auto_pickup_wait -= delta
	if _auto_pickup_wait > 0.0:
		return
	_auto_pickup_wait = 0.15
	var item := _nearest_world_item()
	if item.is_empty():
		return
	if _world_distance(item) > NETWORK_PICKUP_DISTANCE:
		return
	_intent_bridge.submit_pickup(int(item.get("item_id", -1)), int(item.get("revision", -1)))

func _nearest_world_item() -> Dictionary:
	if not uses_network_intents() or not _intent_bridge.has_method("get_world_items"):
		return {}
	var world_variant: Variant = _intent_bridge.get_world_items()
	if not world_variant is Array:
		return {}
	var best: Dictionary = {}
	var best_distance := INF
	for item_variant: Variant in world_variant:
		if not item_variant is Dictionary:
			continue
		var item: Dictionary = item_variant
		var distance := _world_distance(item)
		if distance < best_distance:
			best_distance = distance
			best = item
	return best

func _world_distance(item: Dictionary) -> float:
	var position_variant: Variant = item.get("position", {})
	var at := Vector2.ZERO
	if position_variant is Dictionary:
		at = Vector2(float(position_variant.get("x", 0.0)), float(position_variant.get("y", 0.0)))
	elif position_variant is Vector2:
		at = position_variant
	if not at.is_finite():
		return INF
	return at.distance_to(actor.global_position)
