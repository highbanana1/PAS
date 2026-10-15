extends "res://scene/script/items/item_data.gd"
func _init(amount: float = 30.0) -> void:
	kind = &"health"
	capacity = amount if is_finite(amount) and amount > 0.0 else 30.0
	remaining = capacity
	icon = preload("res://asset/pic/healthitem.png"); icon_region = Rect2(576,576,960,832)
func supports_continuous_use() -> bool: return true
func use_once(actor: Node2D) -> bool:
	var cell: float = actor.health_per_cell
	if not is_full() or actor.max_hp + cell > cell * actor.MAX_HEALTH_CELLS: return false
	actor.max_hp += cell; actor.real_hp += cell; consume(remaining); return true
func heal_continuously(actor: Node2D, amount: float) -> float:
	return actor.get_health_component().heal(amount)
