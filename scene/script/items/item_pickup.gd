extends RigidBody2D
@export_enum("Health", "Jump") var item_type: int = 0
@export_range(1.0, 1000.0, 1.0) var stored_hp: float = 30.0
@export_range(1.0, 200.0, 1.0) var pickup_distance: float = 40.0
var item: RefCounted
var _claimed: bool = false
var _prompt: Label
func configure(data: RefCounted) -> void: item = data
func _ready() -> void:
	if item == null:
		item = load("res://scene/script/items/jump_item_data.gd").new() if item_type == 1 else load("res://scene/script/items/health_item_data.gd").new(stored_hp)
	add_to_group("world_item_pickup"); add_to_group(str(item.kind) + "_item_pickup")
	var sprite := Sprite2D.new(); var atlas := AtlasTexture.new()
	atlas.atlas = item.icon; atlas.region = item.icon_region
	sprite.texture = atlas; sprite.scale = Vector2.ONE * (24.0 / maxf(atlas.region.size.x,atlas.region.size.y))
	sprite.texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST; add_child(sprite)
	_prompt = Label.new(); _prompt.text = "F 拾取"; _prompt.position = Vector2(-20,-30)
	_prompt.add_theme_font_size_override("font_size",10); add_child(_prompt); _prompt.hide()
func can_pick_up(actor: Node2D) -> bool:
	return not _claimed and item != null and is_instance_valid(actor) and actor.get("is_dead") != true and actor.has_method("get_inventory_component") and global_position.distance_to(actor.global_position) <= pickup_distance
func try_pick_up(actor: Node2D) -> bool:
	if not can_pick_up(actor): return false
	_claimed = true
	if not actor.get_inventory_component().add_item(item): _claimed = false; return false
	hide(); remove_from_group("world_item_pickup"); remove_from_group(str(item.kind) + "_item_pickup"); queue_free(); return true
func _process(_delta: float) -> void:
	if _claimed: return
	var nearby := false
	for actor in get_tree().get_nodes_in_group("player"):
		if actor.get("is_locally_controlled") == true and can_pick_up(actor): nearby = true; break
	_prompt.visible = nearby
