extends CharacterBody2D
class_name Player
# 在Player脚本顶部加信号定义
signal health_changed()
signal character_died()

const DASH_AMT: float= 360.0
const DASH_TIME: float= 0.2
const SPEED = 150.0
const JUMP_VELOCITY = -400.0


@onready var animated_sprite: AnimatedSprite2D = $AnimatedSprite2D
@onready var dash: GPUParticles2D = $DashParticles

# 血量配置
@export var max_hp: float = 90
var real_hp: float = max_hp
# 每秒扣血计时器
var damage_timer: float = 0.0

var current_winning_point: Area2D

var can_dash: bool = true
var is_dashing: bool=false
var dash_dir: Vector2= Vector2.RIGHT
var dash_timer: float=0.0
var get_hit: bool =false

@export var hitable: bool = true

# 全局受伤冷却计时器
var hitcooltimer: float = 0.0


@export var jump_count = 1

func _ready() -> void:
	pass

# 修复后的受伤冷却，不会死循环
func hit_cooldown(delta:float)->void:
	if get_hit and hitable:
		$Timer.start()
		hitable = false
		print("hit")
		take_damage(10)
		get_hit=false
	if hitcooltimer > 0:
		hitcooltimer -= delta
		if hitcooltimer <= 0:
			get_hit = false

# 受伤函数
func take_damage(dmg: float):
	real_hp = clamp(real_hp - dmg, 0, max_hp)
	emit_signal("health_changed")

func _die_logic(health: float)-> void:
	if health <=0:
		character_died.emit()
		queue_free()
		
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
	# 每秒自动扣1血测试
	#damage_timer += delta
	#if damage_timer >= 1.0:
	#	take_damage(1)
	#	damage_timer = 0.0

	# 受伤触发冷却计时
	if get_hit and hitcooltimer <= 0:
		hitcooltimer = 3.0

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
	var direction := Input.get_axis("left", "right")
	if direction != 0 and is_on_floor():
		animated_sprite.play("run")
	else:
		animated_sprite.play("idle")
	
	#dashing
	if !is_dashing:
		dash.emitting = false
		if direction:
			velocity.x = direction * SPEED
		else:
			velocity.x = move_toward(velocity.x, 0, SPEED)
	else: 
		#dash动画
		animated_sprite.play("dash")
		#dash残影
		dash.emitting = true
		#翻转dash粒子
		dash.scale.x = -1 if direction < 0 else 1
	_dash_logic(delta)
	
	#根据移动方向翻转精灵朝向
	animated_sprite.flip_h = direction < 0
	
	hit_cooldown(delta)
	_die_logic(real_hp)
	move_and_slide()


func _on_timer_timeout() -> void:
	hitable = true
	$Timer.stop()
