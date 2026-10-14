extends Node
const Guard = preload("res://scene/script/components/guard_component.gd")
const LocalInput = preload("res://scene/script/components/local_combat_input.gd")
const Context = preload("res://scene/script/combat/attack_context.gd")
signal attack_resolved(target: Node2D, result: int)
signal weapon_changed(weapon: int)
signal guard_changed(value: float, maximum: float)
enum Weapon { GUN, SWORD }
var actor: Node2D
var _guard = Guard.new()
var _input = LocalInput.new()
var _weapons: Dictionary = {}
var current_weapon: int = Weapon.GUN
var aim_direction: Vector2 = Vector2.RIGHT
@export var max_guard: float = 100.0:
	get: return _guard.maximum
	set(value): _guard.maximum = value
@export var block_cost: float = 20.0:
	get: return _guard.block_cost
	set(value): _guard.block_cost = value
@export var guard_duration: float = 10.0:
	get: return _guard.duration
	set(value): _guard.duration = value
@export var guard_recovery_duration: float = 15.0:
	get: return _guard.recovery_duration
	set(value): _guard.recovery_duration = value
@export var guard_angle: float = 140.0:
	get: return _guard.angle
	set(value): _guard.angle = value
var guard_value: float:
	get: return _guard.value
	set(value): _guard.value = clampf(value, 0.0, max_guard)
var is_guarding: bool:
	get: return _guard.is_guarding

func _init() -> void:
	_guard.name = "GuardComponent"
	_input.name = "LocalCombatInput"
	add_child(_guard)
	add_child(_input)

func configure(owner_actor: Node2D) -> void:
	actor = owner_actor
	_guard.configure(actor)
	_input.configure(actor, self)
	if not _guard.changed.is_connected(_on_guard_changed):
		_guard.changed.connect(_on_guard_changed)
		_guard.guard_changed.connect(_on_guard_state_changed)

func get_guard_component() -> Node:
	return _guard

func register_weapon(id: int, weapon: Node2D) -> void:
	assert(is_instance_valid(actor), "Configure the weapon owner before registration")
	assert(weapon.has_method("attack") and weapon.has_method("set_active"), "Weapon must implement WeaponBase")
	if _weapons.has(id) and is_instance_valid(_weapons[id]):
		var previous = _weapons[id]
		previous.set_active(false)
		if previous.attack_resolved.is_connected(_on_attack_resolved): previous.attack_resolved.disconnect(_on_attack_resolved)
	_weapons[id] = weapon
	weapon.configure(actor, self)
	if not weapon.attack_resolved.is_connected(_on_attack_resolved): weapon.attack_resolved.connect(_on_attack_resolved)
	weapon.aim(aim_direction)
	refresh_equipped_weapon()

func _current() -> Node2D:
	var weapon = _weapons.get(current_weapon)
	return weapon if is_instance_valid(weapon) and not weapon.is_queued_for_deletion() else null

func current_supports_guard() -> bool:
	var weapon := _current()
	return is_instance_valid(weapon) and weapon.supports_guard

func get_aim_origin() -> Vector2:
	var weapon := _current()
	return weapon.global_position if is_instance_valid(weapon) else actor.global_position

func aim(direction: Vector2) -> void:
	if direction.is_zero_approx() or not direction.is_finite(): return
	aim_direction = direction.normalized()
	for weapon in _weapons.values():
		if is_instance_valid(weapon): weapon.aim(aim_direction)
	_guard.direction = aim_direction
	_update_guard_visual()

func attack(direction: Vector2) -> bool:
	var weapon := _current()
	if not is_instance_valid(actor) or actor.get("is_dead") == true or is_guarding or not is_instance_valid(weapon): return false
	aim(direction)
	return weapon.attack(aim_direction)

func equip_weapon(id: int) -> void:
	if not _weapons.has(id) or not is_instance_valid(_weapons[id]): return
	set_guarding(false)
	for weapon in _weapons.values():
		if is_instance_valid(weapon): weapon.cancel_attack()
	current_weapon = id
	refresh_equipped_weapon()
	weapon_changed.emit(current_weapon)

func cycle_weapon(step: int) -> void:
	for id in _weapons.keys():
		var weapon = _weapons[id]
		if not is_instance_valid(weapon) or weapon.is_queued_for_deletion(): _weapons.erase(id)
	var ids: Array = _weapons.keys()
	ids.sort()
	if ids.is_empty(): return
	var index := ids.find(current_weapon)
	if index < 0: index = -1 if step >= 0 else 0
	equip_weapon(ids[posmod(index + step, ids.size())])

func refresh_equipped_weapon() -> void:
	var alive: bool = is_instance_valid(actor) and actor.get("is_dead") != true
	for id in _weapons:
		if is_instance_valid(_weapons[id]): _weapons[id].set_active(alive and id == current_weapon)
	_update_guard_visual()

func set_guarding(enabled: bool, direction: Vector2 = Vector2.ZERO) -> void:
	if not direction.is_zero_approx(): aim(direction)
	var weapon := _current()
	var allowed: bool = current_supports_guard() and not weapon.is_busy()
	_guard.request_guard(enabled and allowed, aim_direction)
	_update_guard_visual()

func try_block(attack_origin: Vector2) -> bool:
	return _guard.try_block(Context.new(1.0, attack_origin))

func recover_guard(delta: float) -> void:
	# Compatibility entry point; only the adapter polls local Input.
	if _input.enabled(): _guard.hold_requested = _input.is_guard_requested()
	_guard.tick(delta)

func _on_guard_changed(value: float, maximum: float) -> void:
	guard_changed.emit(value, maximum)

func _on_guard_state_changed(_enabled: bool) -> void:
	_update_guard_visual()

func _on_attack_resolved(target: Node2D, result: int) -> void:
	attack_resolved.emit(target, result)

func _update_guard_visual() -> void:
	for id in _weapons:
		var weapon = _weapons[id]
		if is_instance_valid(weapon) and weapon.has_method("set_guard_visual"):
			weapon.set_guard_visual(id == current_weapon and is_guarding, aim_direction)

func _unhandled_input(event: InputEvent) -> void:
	if _input.handle_event(event): get_viewport().set_input_as_handled()

func _process(delta: float) -> void:
	_input.tick(delta)

func suspend() -> void:
	set_guarding(false)
	for weapon in _weapons.values():
		if is_instance_valid(weapon): weapon.cancel_attack()
	refresh_equipped_weapon()

func reset_after_respawn() -> void:
	_guard.reset_state()
	for weapon in _weapons.values():
		if is_instance_valid(weapon): weapon.reset_state()
	refresh_equipped_weapon()
