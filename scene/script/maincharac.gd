extends CharacterBody2D


const SPEED = 300.0
const JUMP_VELOCITY = -400.0

@onready var animated_sprite: AnimatedSprite2D = $AnimatedSprite2D

var jump_count = 1

func _ready() -> void:
	pass


func _physics_process(delta: float) -> void:
	# Add the gravity.
	if not is_on_floor():
		velocity += get_gravity() * delta

	#重制跳跃次数
	if is_on_floor() and jump_count == 0:
		jump_count = 1
	# Handle jump.
	if Input.is_action_just_pressed("jump") and jump_count != 0:
		velocity.y = JUMP_VELOCITY
		jump_count -= 1

	# Get the input direction and handle the movement/deceleration.
	# As good practice, you should replace UI actions with custom gameplay actions.
	var direction := Input.get_axis("right", "left")
	if direction:
		velocity.x = direction * SPEED

		# 根据移动方向翻转精灵朝向
		animated_sprite.flip_h = direction < 0
	else:
		velocity.x = move_toward(velocity.x, 0, SPEED)

	move_and_slide()
