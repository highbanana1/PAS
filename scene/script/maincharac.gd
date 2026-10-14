extends CharacterBody2D
class_name Player
const Health = preload("res://scene/script/components/health_component.gd")
const Receiver = preload("res://scene/script/combat/combat_receiver.gd")
const Context = preload("res://scene/script/combat/attack_context.gd")
const Lifecycle = preload("res://scene/script/components/respawn_component.gd")
const Carry = preload("res://scene/script/components/carry_component.gd")
var _lifecycle = Lifecycle.new()
var _carry = Carry.new()
var _health = Health.new()
var _receiver = Receiver.new()

func _init() -> void:
	_lifecycle.name = "RespawnComponent"
	_carry.name = "CarryComponent"
	add_child(_lifecycle)
	add_child(_carry)
	_health.name = "HealthComponent"
	_receiver.name = "CombatReceiver"
	add_child(_health)
	add_child(_receiver)

func get_respawn_component() -> Node:
	return _lifecycle

func get_carry_component() -> Node:
	return _carry

func get_combat_receiver() -> Node:
	return _receiver

func get_health_component() -> Node:
	return _health

func _on_health_changed(_current: float, _maximum: float) -> void:
	health_changed.emit()

# 在Player脚本顶部加信号定义
signal health_changed()
signal character_died()
signal respawned()
signal respawn_countdown_changed(seconds_left: float)

@export var respawn_delay: float = 5.0:
	get: return _lifecycle.delay
	set(value): _lifecycle.delay = value
@export var is_locally_controlled: bool = true
var is_dead: bool:
	get: return _lifecycle.dead
	set(value): _lifecycle.dead = value
var spawn_position: Vector2:
	get: return _lifecycle.spawn_position
	set(value): _lifecycle.spawn_position = value
var _alive_collision_layer: int
var _alive_collision_mask: int
@onready var respawn_timer: Timer = $RespawnTimer

var respawn_time_left: float:
	get:
		return _lifecycle.time_left

const DASH_AMT: float= 360.0
const DASH_TIME: float= 0.2
const SPEED = 150.0
const JUMP_VELOCITY = -400.0


@onready var animated_sprite: AnimatedSprite2D = $AnimatedSprite2D
@onready var dash: GPUParticles2D = $DashParticles

# 血量配置
@export var max_hp: float = 90
var real_hp: float:
	get: return _health.current
	set(value): _health.set_current(value)
# 每秒扣血计时器
var damage_timer: float = 0.0

var current_winning_point: Area2D:
	get: return _carry.item
	set(value): _carry.item = value

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
	_health.configure(max_hp)
	_health.changed.connect(_on_health_changed)
	_health.depleted.connect(func(): _die_logic(0.0))
	_receiver.configure(self, _health, $WeaponController.try_block)
	spawn_position = global_position
	_alive_collision_layer = collision_layer
	_alive_collision_mask = collision_mask
	_carry.configure(self)
	_lifecycle.configure(respawn_timer, global_position, respawn_delay)
	_lifecycle.died.connect(_on_death)
	_lifecycle.countdown_changed.connect(func(seconds: float): respawn_countdown_changed.emit(seconds))
	_lifecycle.respawn_requested.connect(_on_respawn_requested)
	$WeaponController.refresh_equipped_weapon()

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
func take_damage(dmg: float) -> void:
	_receiver.receive_attack(Context.new(dmg, global_position, null, false))


func receive_attack(dmg: float, attack_origin: Vector2, blockable: bool = true) -> bool:
	# Compatibility API: true only means blocked. New attacks use typed results.
	return _receiver.receive_attack(Context.new(dmg, attack_origin, null, blockable)) == Context.Result.BLOCKED

func _die_logic(health: float) -> void:
	if health <= 0.0: _lifecycle.die()

func _on_death() -> void:
	velocity = Vector2.ZERO
	get_hit = false
	hitable = false
	is_dashing = false
	dash_timer = 0.0
	dash.emitting = false
	$Timer.stop()
	_carry.drop()
	set_deferred("collision_layer", 0)
	set_deferred("collision_mask", 0)
	animated_sprite.hide()
	$gun.hide()
	$gun.set_process(false)
	$WeaponController.suspend()
	# Each player owns a timer; dying never pauses or reloads the shared world.
	character_died.emit()
	respawn_countdown_changed.emit(respawn_timer.time_left)


func respawn(at_position: Vector2) -> void:
	_lifecycle.respawn(at_position)

func _on_respawn_requested(at_position: Vector2) -> void:
	$Timer.stop()
	global_position = at_position
	velocity = Vector2.ZERO
	real_hp = max_hp
	get_hit = false
	hitable = true
	hitcooltimer = 0.0
	damage_timer = 0.0
	is_dashing = false
	can_dash = true
	dash_timer = 0.0
	dash_dir = Vector2.RIGHT
	jump_count = 1
	dash.emitting = false
	current_winning_point = null
	set_deferred("collision_layer", _alive_collision_layer)
	set_deferred("collision_mask", _alive_collision_mask)
	animated_sprite.show()
	animated_sprite.play("idle")
	is_dead = false
	$WeaponController.reset_after_respawn()
	health_changed.emit()
	respawned.emit()


func _on_respawn_timer_timeout() -> void:
	respawn(spawn_position)
		
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
	if is_dead:
		return
	if not is_locally_controlled:
		return
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
	if is_dead:
		return
	move_and_slide()


func _on_timer_timeout() -> void:
	if not is_dead:
		hitable = true
	$Timer.stop()
