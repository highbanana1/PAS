extends Area2D
const Delivery = preload("res://scene/script/components/delivery_receiver.gd")
@export var network_entity_id: String = ""
@export_range(1.0, 512.0, 1.0, "suffix:px") var extraction_radius: float = 48.0
var network_controlled: bool = false
var _delivery = Delivery.new()
var win_countdown: bool = false
var wp: Area2D:
	get: return _delivery.item

func _init() -> void:
	_delivery.name = "DeliveryReceiver"
	add_child(_delivery)

func _ready() -> void:
	_delivery.configure(self)

func get_delivery_receiver() -> Node:
	return _delivery

func _physics_process(_delta: float) -> void:
	if network_controlled: return
	if is_instance_valid(wp): return
	for body in get_overlapping_bodies():
		_on_body_entered(body)
		if is_instance_valid(wp): break

func _on_body_entered(body: Node2D) -> void:
	if network_controlled: return
	if not body.is_in_group("player") or not body.has_method("get_carry_component"): return
	body.get_carry_component().deliver_to(_delivery)

func set_network_controlled(enabled: bool) -> void:
	network_controlled = enabled
