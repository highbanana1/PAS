extends Area2D
const Carryable = preload("res://scene/script/components/carryable_component.gd")
@export var network_entity_id: String = ""
@export var float_offset_y: float = -30.0
var network_controlled: bool = false
var _carryable = Carryable.new()
var is_picked: bool:
	get: return is_instance_valid(_carryable.holder)
var ref: Node2D:
	get: return _carryable.holder

func _init() -> void:
	_carryable.name = "CarryableComponent"
	add_child(_carryable)

func get_carryable_component() -> Node:
	return _carryable

func _ready() -> void:
	add_to_group("network_star")
	_carryable.configure(self, float_offset_y)
	body_entered.connect(_on_player_touch)

func _process(_delta: float) -> void:
	if network_controlled: return
	_carryable.offset_y = float_offset_y
	_carryable.follow()

func _physics_process(_delta: float) -> void:
	if network_controlled: return
	_carryable.settle_pickup()

func _on_player_touch(body: Node2D) -> void:
	if network_controlled: return
	if body.is_in_group("player") and body.has_method("get_carry_component"):
		body.get_carry_component().try_pick_up(self)

func set_network_controlled(enabled: bool) -> void:
	network_controlled = enabled
	if not enabled: visible = true

func apply_network_star(state: Dictionary, carrier: Node2D = null) -> void:
	if not network_controlled: return
	if state.is_empty():
		visible = false
		return
	var phase := String(state.get("state", "FREE"))
	visible = phase != "CONSUMED"
	if phase == "CARRIED" and is_instance_valid(carrier):
		global_position = carrier.global_position + Vector2(0, float_offset_y)
	elif state.get("position") is Vector2:
		global_position = state["position"]

func drop_from_carrier() -> void:
	_carryable.release()

func deliver_to(table: Area2D) -> bool:
	if not is_instance_valid(table) or not table.has_method("get_delivery_receiver"): return false
	return table.get_delivery_receiver().accept(self)
