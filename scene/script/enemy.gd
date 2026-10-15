extends CharacterBody2D
class_name Enemy
const Health = preload("res://scene/script/components/health_component.gd")
const Receiver = preload("res://scene/script/combat/combat_receiver.gd")
const HurtPresentation = preload("res://scene/script/components/enemy_hurt_presentation.gd")
var _hurt_presentation = HurtPresentation.new()
const HealthItemDrops = preload("res://scene/script/components/health_item_drop_component.gd")
var _health_item_drops = HealthItemDrops.new()
@export_range(0.0, 1.0, 0.01) var health_item_drop_chance: float = 0.25
var _health = Health.new()
var _receiver = Receiver.new()

func _init() -> void:
	_health_item_drops.name = "HealthItemDrops"
	add_child(_health_item_drops)
	_hurt_presentation.name = "EnemyHurtPresentation"
	add_child(_hurt_presentation)
	_health.configure(5)
	_health.name = "HealthComponent"
	_receiver.name = "CombatReceiver"
	add_child(_health)
	add_child(_receiver)

func _ready() -> void:
	_health_item_drops.configure(self)
	_receiver.configure(self, _health)
	_health.depleted.connect(_drop_loot_and_die)
	_hurt_presentation.configure(self, _receiver, animated_sprite)

func get_hurt_presentation() -> Node:
	return _hurt_presentation

func get_combat_receiver() -> Node:
	return _receiver

func get_health_component() -> Node:
	return _health


@export var speed: float = 30.0
@export var contact_damage: float = 15.0
var direction: float = 1.0
var health: int:
	get: return int(_health.current)
	set(value): _health.set_current(value)
var get_hited: bool = false
@onready var animated_sprite: AnimatedSprite2D = $AnimatedSprite2D;
@onready var wall_detection_ray: RayCast2D = $walldetection
@onready var ledge_detection_ray: RayCast2D = $LedgeDetectionRay

func _physics_process(delta: float) -> void:
	# Add the gravity.
	if not is_on_floor():
		velocity += get_gravity() * delta
	run(speed)
	_update_direction()

	
	

	move_and_slide()
	
func _update_direction()->void:
	if not wall_detection_ray.is_colliding() and ledge_detection_ray.is_colliding():
		return
	direction*=-1.0
	var wall_detection_pos: Vector2= Vector2(
		wall_detection_ray.target_position.x* -1,
		wall_detection_ray.target_position.y
	)
	wall_detection_ray.target_position = wall_detection_pos
	
	var ledge_detection_pos: Vector2= Vector2(
		ledge_detection_ray.position.x* -1,
		ledge_detection_ray.position.y
	)
	ledge_detection_ray.position = ledge_detection_pos

func run(speed: float)->void:
	velocity.x=speed*direction
	if velocity !=Vector2.ZERO:
		$AnimatedSprite2D.play("move")
	if direction ==-1.0:
		animated_sprite.flip_h=true
	else:
		animated_sprite.flip_h=false

func _on_area_2d_area_entered(area: Area2D) -> void:
		pass

func hurt(damage: int) -> void:
	get_hited = false
	_health.apply_damage(damage)

func _on_area_2d_body_entered(body: Node2D) -> void:
	if body.is_in_group("player") and body.has_method("queue_contact_damage"):
		body.queue_contact_damage(contact_damage, global_position)

func _drop_loot_and_die() -> void:
	_health_item_drops.drop_chance = health_item_drop_chance
	_health_item_drops.drop_enemy_loot(global_position)
	queue_free()
