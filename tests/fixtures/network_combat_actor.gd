extends "res://tests/fixtures/network_match_actor.gd"
const Health = preload("res://scene/script/components/health_component.gd")
const Receiver = preload("res://scene/script/combat/combat_receiver.gd")
var health_component = Health.new()
var receiver = Receiver.new()
var damage_values: Array[float] = []
## Contact-only compatibility fields; weapon damage must neither read nor
## consume these.
var hitable: bool = true
var hitcooltimer: float = 0.0
var contact_invincibility_time: float = 3.0
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
## Authority-managed respawn restores the fixture's existing five-cell health
## and movement state without touching contact-invincibility fields.
func respawn(at_position: Vector2) -> void:
	global_position = at_position
	velocity = Vector2.ZERO
	health_component.set_current(health_component.maximum)
	real_hp = health_component.current
	max_hp = health_component.maximum
	is_dead = false
	_motor.reset_state()
