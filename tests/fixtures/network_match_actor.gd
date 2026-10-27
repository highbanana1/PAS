extends CharacterBody2D

## Minimal loadable actor fixture for the Ticket 02B1 two-process test. It uses
## the real CharacterMotor movement rules but stays free of weapon, item and
## presentation dependencies. MatchAuthority owns its movement; the client
## replica only mirrors the state carried by authoritative snapshots.

const Motor = preload("res://scene/script/components/character_motor.gd")

@export var respawn_delay: float = 999.0
@export var max_hp: float = 150.0
@export var real_hp: float = 150.0
@export var is_dead: bool = false
@export var is_locally_controlled: bool = true
@export var authority_controlled: bool = false
@export var spawn_position: Vector2 = Vector2.ZERO

var _motor

func _init() -> void:
	_motor = Motor.new()
	_motor.name = "CharacterMotor"
	add_child(_motor)

func _ready() -> void:
	collision_layer = 2
	collision_mask = 1
	if get_node_or_null("CollisionShape2D") == null:
		var shape := CollisionShape2D.new()
		shape.name = "CollisionShape2D"
		var rectangle := RectangleShape2D.new()
		rectangle.size = Vector2(18.0, 42.0)
		shape.shape = rectangle
		add_child(shape)
	_motor.configure(self)
	spawn_position = global_position
	set_physics_process(true)

func get_motor() -> Node:
	return _motor

func get_respawn_component() -> Node:
	return null

func set_authority_controlled(enabled: bool) -> void:
	authority_controlled = enabled

func _physics_process(_delta: float) -> void:
	# MatchAuthority drives the body through motor.tick/move_and_slide. The
	# fixture never moves itself, which prevents a hidden local input path.
	pass

func respawn(at_position: Vector2) -> void:
	global_position = at_position
	velocity = Vector2.ZERO
	is_dead = false
	real_hp = max_hp
	_motor.reset_state()

func force_dead() -> void:
	is_dead = true
	real_hp = 0.0
	velocity = Vector2.ZERO
	_motor.reset_state()

func apply_replica_state(state: Dictionary) -> void:
	if state.has("position"):
		global_position = state["position"]
	if state.has("velocity"):
		velocity = state["velocity"]
	if state.has("dead"):
		is_dead = bool(state["dead"])
	if state.has("health"):
		real_hp = float(state["health"])
