extends "res://tests/fixtures/network_match_actor.gd"
const Health = preload("res://scene/script/components/health_component.gd")
const Receiver = preload("res://scene/script/combat/combat_receiver.gd")
var health_component = Health.new()
var receiver = Receiver.new()
var damage_values: Array[float] = []
func _ready() -> void:
	super._ready()
	add_child(health_component)
	add_child(receiver)
	health_component.configure(150.0)
	health_component.damage_cell_size = 30.0
	health_component.changed.connect(_health_changed)
	receiver.configure(self, health_component)
	set_physics_process(false)
func _health_changed(current: float, maximum: float) -> void:
	real_hp = current
	max_hp = maximum
	is_dead = current <= 0.0
	damage_values.append(current)
func get_health_component() -> Node:
	return health_component
func get_combat_receiver() -> Node:
	return receiver
