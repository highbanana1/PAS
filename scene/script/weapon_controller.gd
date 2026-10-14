extends Node

const Feedback = preload("res://scene/script/combat_feedback.gd")

signal weapon_changed(weapon: int)
signal guard_changed(value: float, maximum: float)

enum Weapon { GUN, SWORD }
@export var max_guard: float = 100.0
@export var block_cost: float = 20.0
@export_range(0.1, 60.0) var guard_duration: float = 10.0
@export_range(0.1, 60.0) var guard_recovery_duration: float = 15.0
@export_range(10.0, 180.0) var guard_angle: float = 140.0

var current_weapon: int = Weapon.GUN
var guard_value: float = 100.0
var is_guarding: bool = false
var aim_direction: Vector2 = Vector2.RIGHT
@onready var _player: Player = get_parent()
@onready var _gun: Node2D = $"../gun"
@onready var _sword: Node2D = $"../Sword"


func _ready() -> void:
	guard_value = max_guard
	refresh_equipped_weapon()


func _unhandled_input(event: InputEvent) -> void:
	if _player.is_dead or not _player.is_locally_controlled:
		return
	if event.is_action_pressed("weapon_next"):
		equip_weapon((current_weapon + 1) % 2)
		get_viewport().set_input_as_handled()
	elif event.is_action_pressed("weapon_previous"):
		equip_weapon((current_weapon + 1) % 2)
		get_viewport().set_input_as_handled()


func _process(delta: float) -> void:
	if _player.is_dead or not _player.is_locally_controlled:
		return
	var direction := _player.get_global_mouse_position() - _sword.global_position
	if not direction.is_zero_approx():
		aim_direction = direction.normalized()
	var wants_guard := current_weapon == Weapon.SWORD and Input.is_action_pressed("block")
	set_guarding(wants_guard, aim_direction)
	if current_weapon == Weapon.SWORD and not wants_guard and Input.is_action_just_pressed("fire"):
		_sword.start_swing(aim_direction)
	recover_guard(delta)


func equip_weapon(weapon: int) -> void:
	if weapon != Weapon.GUN and weapon != Weapon.SWORD:
		return
	set_guarding(false)
	_sword.cancel_attack()
	current_weapon = weapon
	refresh_equipped_weapon()
	weapon_changed.emit(current_weapon)


func refresh_equipped_weapon() -> void:
	var alive := not _player.is_dead
	_gun.visible = alive and current_weapon == Weapon.GUN
	_gun.set_process(_gun.visible and _player.is_locally_controlled)
	_sword.active = alive and current_weapon == Weapon.SWORD
	_sword.visible = _sword.active


func set_guarding(enabled: bool, direction: Vector2 = Vector2.ZERO) -> void:
	if not direction.is_zero_approx():
		aim_direction = direction.normalized()
	is_guarding = enabled and current_weapon == Weapon.SWORD and not _player.is_dead and guard_value > 0 and not _sword.is_swinging
	_sword.set_guard_visual(is_guarding, aim_direction)


func try_block(attack_origin: Vector2) -> bool:
	if not is_guarding or _player.is_dead or guard_value <= 0:
		return false
	var toward_attack := (attack_origin - _player.global_position).normalized()
	if aim_direction.dot(toward_attack) < cos(deg_to_rad(guard_angle * 0.5)):
		return false
	Feedback.spawn_guard(_player, toward_attack)
	guard_value = maxf(guard_value - block_cost, 0.0)
	guard_changed.emit(guard_value, max_guard)
	if guard_value <= 0:
		set_guarding(false)
	return true


func recover_guard(delta: float) -> void:
	if _player.is_dead:
		return
	if is_guarding:
		guard_value = maxf(guard_value - max_guard * delta / maxf(guard_duration, 0.1), 0.0)
		if is_zero_approx(guard_value):
			guard_value = 0.0
			set_guarding(false)
		guard_changed.emit(guard_value, max_guard)
		return
	# Exhausted guard stays down until the player releases the button.
	if current_weapon == Weapon.SWORD and Input.is_action_pressed("block"):
		return
	var recovered := minf(guard_value + max_guard * delta / maxf(guard_recovery_duration, 0.1), max_guard)
	if is_equal_approx(recovered, max_guard):
		recovered = max_guard
	if not is_equal_approx(recovered, guard_value):
		guard_value = recovered
		guard_changed.emit(guard_value, max_guard)

func suspend() -> void:
	set_guarding(false)
	_sword.cancel_attack()
	refresh_equipped_weapon()


func reset_after_respawn() -> void:
	guard_value = max_guard
	set_guarding(false)
	_sword.reset_combat_state()
	refresh_equipped_weapon()
	guard_changed.emit(guard_value, max_guard)
