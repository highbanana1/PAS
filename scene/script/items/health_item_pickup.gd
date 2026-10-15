extends Node2D
const TEXTURE = preload("res://asset/pic/healthitem.png")
@export_range(1.0, 200.0, 1.0) var pickup_distance: float = 40.0
var item: RefCounted
var _claimed: bool = false
var _prompt: Label
func configure(data: RefCounted) -> void:
	item = data
func _ready() -> void:
	add_to_group("health_item_pickup")
	var sprite := Sprite2D.new()
	var atlas := AtlasTexture.new(); atlas.atlas = TEXTURE
	atlas.region = Rect2(576, 576, 960, 832)
	sprite.texture = atlas; sprite.scale = Vector2.ONE * 0.025
	sprite.texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST; add_child(sprite)
	_prompt = Label.new(); _prompt.text = "F 拾取"
	_prompt.position = Vector2(-20,-30); _prompt.add_theme_font_size_override("font_size", 10)
	add_child(_prompt); _prompt.hide()
func can_pick_up(actor: Node2D) -> bool:
	return not _claimed and item != null and is_instance_valid(actor) and actor.get("is_dead") != true and actor.has_method("get_health_item_component") and global_position.distance_to(actor.global_position) <= pickup_distance
func try_pick_up(actor: Node2D) -> bool:
	if not can_pick_up(actor): return false
	_claimed = true
	if not actor.get_health_item_component().add_item(item):
		_claimed = false; return false
	hide(); remove_from_group("health_item_pickup"); queue_free(); return true
func _process(_delta: float) -> void:
	if _claimed: return
	var nearby := false
	for actor in get_tree().get_nodes_in_group("player"):
		if actor.get("is_locally_controlled") == true and can_pick_up(actor): nearby = true; break
	_prompt.visible = nearby
