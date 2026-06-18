extends CharacterBody2D
class_name Enemy

@export var speed: float = 30.0
var direction: float = 1.0
var health: int = 5
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

func hurt(damage: int)-> void:
	if health > 0 and get_hited:
		health-=damage
		get_hited = false
	if health <=0:
		queue_free()

func _on_area_2d_body_entered(body: Node2D) -> void:
	if body.is_in_group("player"):
		body.get_hit = true
