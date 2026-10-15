extends CharacterBody2D
class_name Player
const Health = preload("res://scene/script/components/health_component.gd")
const Receiver = preload("res://scene/script/combat/combat_receiver.gd")
const Context = preload("res://scene/script/combat/attack_context.gd")
const Lifecycle = preload("res://scene/script/components/respawn_component.gd")
const Carry = preload("res://scene/script/components/carry_component.gd")
const Motor = preload("res://scene/script/components/character_motor.gd")
const Presentation = preload("res://scene/script/components/combat_presentation.gd")
var _presentation = Presentation.new()
var _motor = Motor.new()
var _lifecycle = Lifecycle.new()
var _carry = Carry.new()
const HurtPresentation = preload("res://scene/script/components/player_hurt_presentation.gd")
var _hurt_presentation = HurtPresentation.new()
const HealthItems = preload("res://scene/script/components/health_item_component.gd")
var _health_items = HealthItems.new()
const ItemInput = preload("res://scene/script/components/local_item_input.gd")
var _item_input = ItemInput.new()
@export_range(0.1, 30.0, 0.1, "suffix:s") var health_item_use_duration: float = 2.0:
	get: return _health_items.use_duration
	set(value): _health_items.use_duration = value
@export_range(0.1, 2.0, 0.05, "suffix:s") var health_item_hold_threshold: float = 0.3:
	get: return _item_input.hold_threshold
	set(value): _item_input.hold_threshold = value
const HealthItemDrops = preload("res://scene/script/components/health_item_drop_component.gd")
var _health_item_drops = HealthItemDrops.new()
var _health = Health.new()
var _receiver = Receiver.new()

func _init() -> void:
	_item_input.name = "LocalItemInput"
	add_child(_item_input)
	_health_item_drops.name = "HealthItemDrops"
	add_child(_health_item_drops)
	_health_items.name = "HealthItems"
	add_child(_health_items)
	_hurt_presentation.name = "PlayerHurtPresentation"
	add_child(_hurt_presentation)
	_presentation.name = "CombatPresentation"
	add_child(_presentation)
	_motor.name = "CharacterMotor"
	add_child(_motor)
	_lifecycle.name = "RespawnComponent"
	_carry.name = "CarryComponent"
	add_child(_lifecycle)
	add_child(_carry)
	_health.name = "HealthComponent"
	_receiver.name = "CombatReceiver"
	add_child(_health)
	add_child(_receiver)

func get_guard_component() -> Node:
	return $WeaponController.get_guard_component()

func get_weapon_controller() -> Node:
	return $WeaponController

func get_motor() -> Node:
	return _motor

func get_respawn_component() -> Node:
	return _lifecycle

func get_carry_component() -> Node:
	return _carry

func get_hurt_presentation() -> Node:
	return _hurt_presentation

func get_combat_receiver() -> Node:
	return _receiver

func get_health_item_drop_component() -> Node:
	return _health_item_drops

func get_inventory_component() -> Node:
	return _health_items

func get_health_item_component() -> Node:
	return _health_items

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
const MAX_HEALTH_CELLS: int = 8
@export_range(1, 8, 1) var starting_health_cells: int = 5
@export_range(1.0, 1000.0, 1.0, "or_greater") var health_per_cell: float = 30.0
var max_hp: float:
	get: return _health.maximum
	set(value): _health.set_maximum(minf(value, health_per_cell * MAX_HEALTH_CELLS))
var real_hp: float:
	get: return _health.current
	set(value): _health.set_current(value)
# 每秒扣血计时器
var damage_timer: float = 0.0

var current_winning_point: Area2D:
	get: return _carry.item
	set(value): _carry.item = value

var can_dash: bool:
	get: return _motor.can_dash
	set(value): _motor.can_dash = value
var is_dashing: bool:
	get: return _motor.is_dashing
	set(value): _motor.is_dashing = value
var dash_dir: Vector2:
	get: return _motor.dash_dir
	set(value): _motor.dash_dir = value
var dash_timer: float:
	get: return _motor.dash_timer
	set(value): _motor.dash_timer = value
var get_hit: bool =false
var _pending_contact: RefCounted

@export var hitable: bool = true
## Contact-hit invincibility in seconds. Zero disables this protection.
@export_range(0.0, 30.0, 0.05, "or_greater", "suffix:s") var hit_invincibility_time: float = 3.0

# 全局受伤冷却计时器
var hitcooltimer: float = 0.0


var jump_count: int:
	get: return _motor.jump_count
	set(value): _motor.jump_count = value

func _ready() -> void:
	_health_items.configure(self)
	_item_input.configure(self, _health_items)
	_health_item_drops.configure(self)
	_motor.configure(self)
	_health.damage_cell_size = health_per_cell
	_health.configure(clampi(starting_health_cells, 1, MAX_HEALTH_CELLS) * health_per_cell)
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
	$WeaponController.configure(self)
	$WeaponController.register_weapon(0, $gun)
	$WeaponController.register_weapon(1, $Sword)
	_presentation.configure(self, $WeaponController, get_guard_component())
	_hurt_presentation.configure(self, _receiver, animated_sprite)

## Contact damage is actor-owned; physical contact cannot be blocked by a sword.
func queue_contact_damage(amount: float, origin: Vector2) -> void:
	if is_dead or not hitable or not is_finite(amount) or amount <= 0.0 or not origin.is_finite(): return
	if _pending_contact != null: return
	_pending_contact = Context.new(amount, origin, null, false)
	get_hit = true

# 修复后的受伤冷却，不会死循环
func hit_cooldown(delta: float) -> void:
	if get_hit and hitable:
		if hit_invincibility_time > 0.0:
			$Timer.start(hit_invincibility_time)
			hitable = false
		var contact = _pending_contact
		_pending_contact = null
		if contact != null: _receiver.receive_attack(contact)
		else: take_damage(15)
		get_hit = false
	if hitcooltimer > 0.0:
		hitcooltimer -= delta
		if hitcooltimer <= 0.0:
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
	_health_item_drops.drop_inventory(_health_items.take_all_items(), global_position)
	_motor.reset_state()
	get_hit = false
	_pending_contact = null
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
	# Respawn restores starting health; maximum capacity remains available for upgrades.
	real_hp = minf(max_hp, clampi(starting_health_cells, 1, MAX_HEALTH_CELLS) * health_per_cell)
	get_hit = false
	_pending_contact = null
	hitable = true
	hitcooltimer = 0.0
	damage_timer = 0.0
	_motor.reset_state()
	dash.emitting = false
	current_winning_point = null
	set_deferred("collision_layer", _alive_collision_layer)
	set_deferred("collision_mask", _alive_collision_mask)
	_hurt_presentation.reset_state()
	animated_sprite.show()
	animated_sprite.flip_h = false
	animated_sprite.play("idle")
	is_dead = false
	$WeaponController.reset_after_respawn()
	respawned.emit()


func _on_respawn_timer_timeout() -> void:
	respawn(spawn_position)
		
func _physics_process(delta: float) -> void:
	if is_dead or not is_locally_controlled:
		return
	if get_hit and hitcooltimer <= 0.0:
		hitcooltimer = hit_invincibility_time
	var direction := Input.get_axis("left", "right")
	animated_sprite.play("run" if direction != 0.0 and is_on_floor() else "idle")
	if is_dashing:
		animated_sprite.play("dash")
		dash.emitting = true
		dash.scale.x = -1 if direction < 0.0 else 1
	else:
		dash.emitting = false
	var move_input := Vector2(direction, Input.get_axis("up", "down"))
	if Input.is_action_just_pressed("jump"): _motor.request_jump()
	if Input.is_action_just_pressed("dash"): _motor.request_dash(move_input)
	_motor.tick(delta, move_input)
	animated_sprite.flip_h = direction < 0.0
	hit_cooldown(delta)
	_die_logic(real_hp)
	if not is_dead: move_and_slide()


func _on_timer_timeout() -> void:
	if not is_dead:
		hitable = true
	$Timer.stop()
