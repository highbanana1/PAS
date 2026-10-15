extends "res://scene/script/items/item_data.gd"
func _init() -> void:
	kind = &"jump"
	icon = preload("res://asset/pic/jumpitem.png"); icon_region = Rect2(192,128,1664,1664)
func use_once(actor: Node2D) -> bool:
	if remaining <= 0.0 or not actor.get_motor().grant_extra_air_jump(): return false
	consume(1.0); return true
