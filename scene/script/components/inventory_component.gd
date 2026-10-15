extends Node
signal changed()
var actor: Node2D
var items: Array = []
var selected: bool = true
var selected_index: int = 0
var auto_pickup_enabled: bool = true
var _pickup_wait: float = 0.0
var using_continuously: bool = false
@export_range(1, 3, 1) var slot_count: int = 3
@export_range(0.1, 30.0, 0.1) var use_duration: float = 2.0
func configure(owner_actor: Node2D) -> void: actor = owner_actor
func _alive() -> bool: return is_instance_valid(actor) and actor.get("is_dead") != true
func current_item() -> RefCounted:
	return items[selected_index] if selected and selected_index >= 0 and selected_index < items.size() else null
func add_item(item: RefCounted) -> bool:
	if not _alive() or item == null or not is_finite(item.remaining) or item.remaining <= 0.0 or items.size() >= slot_count: return false
	if item.holder != null and is_instance_valid(item.holder.get_ref()): return false
	item.holder = weakref(self); items.append(item); changed.emit(); return true
func select_item(index: int = 0) -> void:
	if not _alive() or index < 0 or index >= slot_count: return
	cancel_use(); selected = true; selected_index = index; changed.emit()
func deselect_item() -> void:
	selected = false; cancel_use(); changed.emit()
func use_selected() -> bool:
	var item = current_item()
	if not _alive() or item == null or not item.use_once(actor): return false
	if is_zero_approx(item.remaining): _remove_selected()
	else: changed.emit()
	return true
func begin_continuous_use() -> void:
	var item = current_item()
	using_continuously = _alive() and item != null and item.supports_continuous_use()
func tick_continuous_use(delta: float) -> void:
	if not _alive(): cancel_use(); return
	var item = current_item()
	if not using_continuously or item == null or not is_finite(delta) or delta <= 0.0: return
	var request: float = minf(item.remaining, item.capacity * delta / maxf(use_duration, 0.1))
	var restored: float = item.heal_continuously(actor, request)
	item.consume(restored)
	if is_zero_approx(item.remaining): _remove_selected()
	elif restored > 0.0: changed.emit()
func _remove_selected() -> void:
	items[selected_index].holder = null; items.remove_at(selected_index)
	selected_index = mini(selected_index, maxi(items.size() - 1, 0))
	cancel_use(); changed.emit()
func cancel_use() -> void: using_continuously = false
func take_all_items() -> Array:
	cancel_use(); selected = false; selected_index = 0
	var result := items.duplicate()
	for item in result: item.holder = null
	items.clear(); changed.emit(); return result
func try_pick_up(pickup: Node2D) -> bool:
	return _alive() and is_instance_valid(pickup) and pickup.has_method("try_pick_up") and pickup.try_pick_up(actor)
func pick_up_nearest() -> bool:
	if not _alive(): return false
	var candidates: Array = []
	for pickup in get_tree().get_nodes_in_group("world_item_pickup"):
		if pickup.can_pick_up(actor): candidates.append(pickup)
	candidates.sort_custom(func(a,b):
		var da: float = a.global_position.distance_squared_to(actor.global_position)
		var db: float = b.global_position.distance_squared_to(actor.global_position)
		return a.get_instance_id() < b.get_instance_id() if is_equal_approx(da,db) else da < db)
	return not candidates.is_empty() and try_pick_up(candidates[0])

func toggle_auto_pickup() -> bool:
	auto_pickup_enabled = not auto_pickup_enabled
	_pickup_wait = 0.0
	changed.emit()
	return auto_pickup_enabled

func tick_auto_pickup(delta: float) -> void:
	if not _alive() or not auto_pickup_enabled or items.size() >= slot_count or not is_finite(delta) or delta <= 0.0: return
	_pickup_wait -= delta
	if _pickup_wait > 0.0: return
	_pickup_wait = 0.15
	# Bounded by slot capacity; successful pickups leave the world group immediately.
	while items.size() < slot_count and pick_up_nearest(): pass
