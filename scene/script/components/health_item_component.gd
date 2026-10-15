extends Node
signal changed()
var actor: Node2D
var items: Array = []
var selected: bool = false
var using_continuously: bool = false
@export_range(0.1, 30.0, 0.1) var use_duration: float = 2.0
func configure(owner_actor: Node2D) -> void:
	actor = owner_actor
func _alive() -> bool:
	return is_instance_valid(actor) and actor.get("is_dead") != true
func add_item(item: RefCounted) -> bool:
	if not _alive() or item == null or item.remaining <= 0.0: return false
	if item.holder != null and is_instance_valid(item.holder.get_ref()): return false
	item.holder = weakref(self)
	items.append(item); changed.emit(); return true
func select_item() -> void:
	if not _alive(): return
	selected = true; changed.emit()
func deselect_item() -> void:
	selected = false; cancel_use(); changed.emit()
func use_selected() -> bool:
	if not _alive() or not selected or items.is_empty(): return false
	var item = items[0]
	if not item.is_full(): return false
	var cell: float = actor.health_per_cell
	if actor.max_hp + cell > cell * actor.MAX_HEALTH_CELLS: return false
	actor.max_hp += cell
	actor.real_hp += cell
	_remove_first(); return true
func begin_continuous_use() -> void:
	using_continuously = _alive() and selected and not items.is_empty()
func tick_continuous_use(delta: float) -> void:
	if not _alive(): cancel_use(); return
	if not using_continuously or items.is_empty() or not is_finite(delta) or delta <= 0.0: return
	var item = items[0]
	var request: float = minf(item.remaining, item.capacity * delta / maxf(use_duration, 0.1))
	var restored: float = actor.get_health_component().heal(request)
	item.consume(restored)
	if is_zero_approx(item.remaining): _remove_first()
	elif restored > 0.0: changed.emit()
func _remove_first() -> void:
	items[0].holder = null; items.pop_front()
	cancel_use(); changed.emit()
func cancel_use() -> void:
	using_continuously = false
func take_all_items() -> Array:
	cancel_use(); selected = false
	var result := items.duplicate()
	for item in result: item.holder = null
	items.clear(); changed.emit(); return result

func try_pick_up(pickup: Node2D) -> bool:
	return _alive() and is_instance_valid(pickup) and pickup.has_method("try_pick_up") and pickup.try_pick_up(actor)
func pick_up_nearest() -> bool:
	if not _alive(): return false
	var candidates: Array = []
	for pickup in get_tree().get_nodes_in_group("health_item_pickup"):
		if pickup.can_pick_up(actor): candidates.append(pickup)
	candidates.sort_custom(func(a, b):
		var da: float = a.global_position.distance_squared_to(actor.global_position)
		var db: float = b.global_position.distance_squared_to(actor.global_position)
		return a.get_instance_id() < b.get_instance_id() if is_equal_approx(da, db) else da < db)
	return not candidates.is_empty() and try_pick_up(candidates[0])
