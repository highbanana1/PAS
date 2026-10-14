extends Area2D
const Carryable = preload("res://scene/script/components/carryable_component.gd")
@export var float_offset_y: float = -30.0
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
	_carryable.configure(self, float_offset_y)
	global_position = Vector2(100, -100)
	body_entered.connect(_on_player_touch)

func _process(_delta: float) -> void:
	_carryable.offset_y = float_offset_y
	_carryable.follow()

func _physics_process(_delta: float) -> void:
	_carryable.settle_pickup()

func _on_player_touch(body: Node2D) -> void:
	if body.is_in_group("player") and body.has_method("get_carry_component"):
		body.get_carry_component().try_pick_up(self)

func drop_from_carrier() -> void:
	_carryable.release()

func deliver_to(table: Area2D) -> bool:
	if not is_instance_valid(table) or not table.has_method("get_delivery_receiver"): return false
	return table.get_delivery_receiver().accept(self)
