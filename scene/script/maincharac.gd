extends CharacterBody2D
class_name Player
const Health = preload("res://scene/script/components/health_component.gd")
const Receiver = preload("res://scene/script/combat/combat_receiver.gd")
const Context = preload("res://scene/script/combat/attack_context.gd")
const Lifecycle = preload("res://scene/script/components/respawn_component.gd")
const Carry = preload("res://scene/script/components/carry_component.gd")
const Motor = preload("res://scene/script/components/character_motor.gd")
const Presentation = preload("res://scene/script/components/combat_presentation.gd")
const HealthData = preload("res://scene/script/items/health_item_data.gd")
const JumpData = preload("res://scene/script/items/jump_item_data.gd")
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

func get_authority_combat_config() -> Dictionary:
	return $WeaponController.get_authority_combat_config()

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
## Set by the offline authority adapter. Movement and respawn then advance via
## MatchAuthority; the direct input path remains only for unbound compatibility.
var authority_controlled: bool = false
## Set only by MatchNetworkBridge when this actor participates in a networked
## match. Offline play and the offline authority adapter keep this false.
var network_authority: bool = false
## True only for the host-side simulation actor. Remote replicas must never
## decide contact damage, while the host must keep the existing contact rules.
var network_simulation_authority: bool = false
var _extracted: bool = false
var _authority_item_signature: String = ""
## Replica presentation dedupe. The presenter only reacts to a strictly newer
## life or a changed dead flag on the current life, so duplicate/out-of-order
## snapshots cannot replay death or respawn visuals.
var _applying_replica: bool = false
var _replica_initialized: bool = false
var _replica_life_id: int = 0
var _replica_dead: bool = false
var _replica_death_plays: int = 0
var _replica_respawn_plays: int = 0
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
	# Remote replicas only mirror host health. The host simulation keeps the
	# existing contact-damage path and its contact-only invincibility window.
	if network_authority and not network_simulation_authority: return
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
	# Remote replicas cannot decide direct damage; the host simulation can still
	# apply existing non-weapon/contact flows through CombatReceiver.
	if network_authority and not network_simulation_authority: return
	_receiver.receive_attack(Context.new(dmg, global_position, null, false))


func receive_attack(dmg: float, attack_origin: Vector2, blockable: bool = true) -> bool:
	# Compatibility API: true only means blocked. New attacks use typed results.
	return _receiver.receive_attack(Context.new(dmg, attack_origin, null, blockable)) == Context.Result.BLOCKED

func _die_logic(health: float) -> void:
	if _applying_replica: return
	if health <= 0.0: _lifecycle.die()

func _on_death() -> void:
	var dropped_items := _health_items.take_all_items()
	# Authority-owned deaths drop exactly once from the item checkpoint. The
	# local component must not create a second world item in network mode.
	if not network_authority:
		_health_item_drops.drop_inventory(dropped_items, global_position)
	_motor.reset_state()
	get_hit = false
	_pending_contact = null
	hitable = false
	is_dashing = false
	dash_timer = 0.0
	dash.emitting = false
	$Timer.stop()
	if authority_controlled: respawn_timer.stop()
	_carry.drop()
	set_deferred("collision_layer", 0)
	set_deferred("collision_mask", 0)
	animated_sprite.hide()
	$gun.hide()
	$gun.set_process(false)
	$WeaponController.suspend()
	# Each player owns a timer; dying never pauses or reloads the shared world.
	character_died.emit()
	# Authority-managed respawns stop the real timer, so read the unified value.
	respawn_countdown_changed.emit(respawn_time_left)


func respawn(at_position: Vector2) -> void:
	_lifecycle.respawn(at_position)

func set_authority_controlled(enabled: bool) -> void:
	if authority_controlled == enabled: return
	authority_controlled = enabled
	_lifecycle.set_authority_managed(enabled)
	if enabled: respawn_timer.stop()

## Network mode: host checkpoints drive guard, health and backpack state; local
## adapters still read the same keys but submit intents only. Offline behavior is
## unchanged.
func set_network_authority(enabled: bool, simulation_authority: bool = false) -> void:
	var next_simulation_authority := enabled and simulation_authority
	if network_authority == enabled and network_simulation_authority == next_simulation_authority:
		return
	network_authority = enabled
	network_simulation_authority = next_simulation_authority
	$WeaponController.set_network_authority(enabled)
	_item_input.set_process(true)
	if enabled:
		_item_input.reset_state()
		_health_items.cancel_use()
	else:
		set_extracted(false)
		clear_network_intents()
		_reset_replica_presentation()

func bind_network_intents(bridge: Node, player_id: StringName) -> bool:
	if not network_authority:
		return false
	var combat_ok: bool = $WeaponController.bind_network_intents(bridge, player_id)
	var item_ok: bool = _item_input.bind_network_intents(bridge, player_id)
	return combat_ok and item_ok

func clear_network_intents() -> void:
	$WeaponController.clear_network_intents()
	_item_input.clear_network_intents()

func apply_authoritative_guard(state: Dictionary) -> void:
	$WeaponController.apply_authoritative_guard(state)

## Client presentation seam. Authoritative state only moves/renders the actor
## and plays one death/respawn transition per life; it never decides damage,
## drops or respawn. Duplicate and old-life states are ignored for presentation.
func apply_replica_state(state: Dictionary) -> bool:
	if state.is_empty():
		return false
	var life := int(state.get("life_id", _replica_life_id))
	if _replica_initialized and life < _replica_life_id:
		return false
	if state.has("extracted"):
		set_extracted(bool(state["extracted"]))
	var dead := bool(state.get("dead", _replica_dead))
	_applying_replica = true
	if state.has("position"):
		var position: Variant = state["position"]
		if position is Vector2 and (position as Vector2).is_finite():
			global_position = position
	if state.has("velocity"):
		var velocity_value: Variant = state["velocity"]
		if velocity_value is Vector2 and (velocity_value as Vector2).is_finite():
			velocity = velocity_value
	if not _replica_initialized:
		_replica_initialized = true
		_replica_life_id = life
		_replica_dead = dead
		if dead:
			_play_replica_death()
	elif life > _replica_life_id:
		_replica_life_id = life
		_replica_dead = dead
		if dead:
			_play_replica_death()
		else:
			_play_replica_respawn()
	elif dead != _replica_dead:
		_replica_dead = dead
		if dead:
			_play_replica_death()
		else:
			_play_replica_respawn()
	if state.has("max_health"):
		var max_value: Variant = state["max_health"]
		if max_value is float or max_value is int:
			max_hp = float(max_value)
	if state.has("health"):
		var health_value: Variant = state["health"]
		if health_value is float or health_value is int:
			real_hp = clampf(float(health_value), 0.0, max_hp)
	if state.has("respawn_remaining") and _lifecycle.authority_managed:
		_lifecycle.set_authority_remaining(float(state["respawn_remaining"]))
	_applying_replica = false
	return true

## Winning players stay in the scene as spectators, with their camera free to
## show the ongoing match. They cannot collide or receive further combat hits.
func set_extracted(enabled: bool) -> void:
	if _extracted == enabled: return
	_extracted = enabled
	if enabled:
		velocity = Vector2.ZERO
		$WeaponController.suspend()
		$gun.set_active(false)
		$Sword.set_active(false)
		collision_layer = 0
		collision_mask = 0
		$AnimatedSprite2D.visible = false
	else:
		collision_layer = 0 if is_dead else _alive_collision_layer
		collision_mask = 0 if is_dead else _alive_collision_mask
		$AnimatedSprite2D.visible = not is_dead
		$WeaponController.refresh_equipped_weapon()

func get_replica_presentation_counts() -> Dictionary:
	return {
		"death": _replica_death_plays,
		"respawn": _replica_respawn_plays,
	}

func _reset_replica_presentation() -> void:
	_replica_initialized = false
	_replica_life_id = 0
	_replica_dead = false
	_replica_death_plays = 0
	_replica_respawn_plays = 0

func _play_replica_death() -> void:
	_lifecycle.dead = true
	_motor.reset_state()
	get_hit = false
	_pending_contact = null
	hitable = false
	is_dashing = false
	dash_timer = 0.0
	dash.emitting = false
	$Timer.stop()
	respawn_timer.stop()
	set_deferred("collision_layer", 0)
	set_deferred("collision_mask", 0)
	animated_sprite.hide()
	$gun.hide()
	$gun.set_process(false)
	$WeaponController.suspend()
	_item_input.reset_state()
	_health_items.cancel_use()
	_replica_death_plays += 1
	character_died.emit()
	respawn_countdown_changed.emit(respawn_time_left)

func _play_replica_respawn() -> void:
	_apply_respawn_presentation(_spawn_position_for_replica())
	_replica_dead = false
	_replica_respawn_plays += 1
	respawned.emit()

func _spawn_position_for_replica() -> Vector2:
	if global_position.is_finite():
		return global_position
	return spawn_position

func apply_authoritative_items(records: Array) -> void:
	var normalized: Array = []
	for record_variant: Variant in records:
		if record_variant is Dictionary:
			normalized.append(record_variant)
	normalized.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
		return int(a.get("item_id", 0)) < int(b.get("item_id", 0)))
	var signature := JSON.stringify(normalized)
	if signature == _authority_item_signature:
		return
	_authority_item_signature = signature
	_health_items.cancel_use()
	for item in _health_items.items:
		if item != null: item.holder = null
	_health_items.items.clear()
	for record: Dictionary in normalized:
		var item_type := String(record.get("type", ""))
		var capacity := float(record.get("capacity", 0.0))
		var remaining := float(record.get("remaining", 0.0))
		var data: RefCounted
		if item_type == "health":
			data = HealthData.new(capacity)
		elif item_type == "jump":
			data = JumpData.new()
		else:
			continue
		data.item_id = int(record.get("item_id", 0))
		data.revision = int(record.get("revision", 0))
		if is_finite(capacity) and capacity > 0.0:
			data.capacity = capacity
		data.remaining = clampf(remaining, 0.0, capacity if capacity > 0.0 else data.capacity)
		_health_items.add_item(data)
	_health_items.changed.emit()

func _on_respawn_requested(at_position: Vector2) -> void:
	_apply_respawn_presentation(at_position)
	respawned.emit()

## Shared presentation-only respawn. It never changes authority ownership of
## drops/respawn; the offline lifecycle and the network presenter both call it.
func _apply_respawn_presentation(at_position: Vector2) -> void:
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


func _on_respawn_timer_timeout() -> void:
	respawn(spawn_position)
		
func _physics_process(delta: float) -> void:
	if is_dead or _extracted or not is_locally_controlled:
		return
	if get_hit and hitcooltimer <= 0.0:
		hitcooltimer = hit_invincibility_time
	if authority_controlled:
		var facing := signf(velocity.x)
		animated_sprite.play("run" if facing != 0.0 and is_on_floor() else "idle")
		if is_dashing:
			animated_sprite.play("dash")
			dash.emitting = true
			if facing != 0.0: dash.scale.x = -1 if facing < 0.0 else 1
		else:
			dash.emitting = false
		if facing != 0.0: animated_sprite.flip_h = facing < 0.0
		hit_cooldown(delta)
		_die_logic(real_hp)
		return
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
