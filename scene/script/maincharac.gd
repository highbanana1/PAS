extends CharacterBody2D

const DASH_AMT: float= 360.0
const DASH_TIME: float= 0.2
const SPEED = 200.0
const JUMP_VELOCITY = -400.0
var can_dash: bool = true
var is_dashing: bool=false
var dash_dir: Vector2= Vector2.RIGHT
var dash_timer: float=0.0
@onready var animated_sprite: AnimatedSprite2D = $AnimatedSprite2D

var jump_count = 1

func _ready() -> void:
	pass


func _dash_logic(delta: float)-> void:
	var input_dir: Vector2 = Vector2(
		Input.get_axis("left","right"),
		Input.get_axis("up","down")
	).normalized()
	
	if input_dir.x != 0:
		dash_dir.x = input_dir.x
		
	if can_dash and Input.is_action_just_pressed("dash"):
		var final_dash_dir: Vector2 = dash_dir
		if input_dir.y !=0 and input_dir.x ==0:
			final_dash_dir.x=0
		final_dash_dir.y=input_dir.y
		
		can_dash = false
		is_dashing = true
		dash_timer = DASH_TIME
		
		velocity = final_dash_dir * DASH_AMT
	
	if is_dashing:
		
		dash_timer -=delta
		if dash_timer <= 0.0:
			is_dashing= false
		

func _physics_process(delta: float) -> void:
	# Add the gravity.
	if not is_on_floor():
		if !is_dashing:
			velocity += get_gravity() * delta

	#重制跳跃次数
	if is_on_floor() and jump_count == 0:
		jump_count = 1
	if is_on_floor():
		if !is_dashing and !can_dash:
			can_dash= true
		
	# Handle jump.
	if Input.is_action_just_pressed("jump") and jump_count != 0:
		velocity.y = JUMP_VELOCITY
		jump_count -= 1

	# Get the input direction and handle the movement/deceleration.
	# As good practice, you should replace UI actions with custom gameplay actions.
	var direction := Input.get_axis("left", "right")
	if direction !=0 and is_on_floor():
		animated_sprite.play("run")
	else:
		animated_sprite.play("idle")
	if !is_dashing:
		if direction:
			velocity.x = direction * SPEED

			# 根据移动方向翻转精灵朝向
			animated_sprite.flip_h = direction < 0
		else:
			
			velocity.x = move_toward(velocity.x, 0, SPEED)
	_dash_logic(delta)
	move_and_slide()
