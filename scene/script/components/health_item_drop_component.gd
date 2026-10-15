extends Node
const Pickup = preload("res://scene/health_item_pickup.tscn")
const Data = preload("res://scene/script/items/health_item_data.gd")
var actor: Node2D
@export_range(0.0, 1.0, 0.01) var drop_chance: float = 0.25
var _enemy_dropped: bool = false
func configure(owner_actor: Node2D) -> void:
	actor = owner_actor
func spawn_item(item: RefCounted, at: Vector2) -> Node2D:
	if item == null or item.remaining <= 0.0 or not at.is_finite(): return null
	var world: Node = get_tree().current_scene
	if world == null: world = get_tree().root
	var pickup = Pickup.instantiate(); pickup.configure(item)
	world.add_child(pickup); pickup.global_position = at
	return pickup
func drop_enemy_loot(at: Vector2) -> void:
	if _enemy_dropped: return
	_enemy_dropped = true
	if randf() < clampf(drop_chance, 0.0, 1.0): spawn_item(Data.new(30.0), at)
func drop_inventory(items: Array, at: Vector2) -> void:
	for index in range(items.size()):
		spawn_item(items[index], at + Vector2((index - (items.size() - 1) * 0.5) * 16.0, 0))
