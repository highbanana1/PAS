extends "res://scene/script/weapons/weapon_base.gd"
const BULLET = preload("res://scene/bullet.tscn")

@export_range(1, 20) var pellet_count: int = 5
@export_range(0.0, 90.0) var spread_degrees: float = 15.0
@export_range(1, 100) var pellet_damage: int = 2

var _spread_rng := RandomNumberGenerator.new()

func _init() -> void:
	_spread_rng.randomize()

func set_spread_seed(value: int) -> void:
	_spread_rng.seed = value

@onready var muzzle: Marker2D = $Marker2D

func set_active(enabled: bool) -> void:
	super.set_active(enabled)
	# Remote gun pose/commands are supplied externally, never polled locally.
	set_process(enabled and is_instance_valid(actor) and actor.get("is_locally_controlled") != false)

func aim(direction: Vector2) -> void:
	super.aim(direction)
	global_rotation = aim_direction.angle()
	rotation_degrees = wrapf(rotation_degrees, 0.0, 360.0)
	scale.y = -1.0 if rotation_degrees > 90.0 and rotation_degrees < 270.0 else 1.0

func _process(_delta: float) -> void:
	if active: aim(aim_direction)

func generate_pellet_offsets() -> Array[float]:
	var count := clampi(pellet_count, 1, 20)
	var spread := spread_degrees if is_finite(spread_degrees) else 15.0
	var half_angle := deg_to_rad(clampf(spread, 0.0, 90.0)) * 0.5
	var offsets: Array[float] = []
	for index in range(count):
		# Independent center-weighted samples, no fixed pattern or center pellet.
		var offset := 0.0 if count == 1 else (_spread_rng.randf_range(-0.5,0.5) + _spread_rng.randf_range(-0.5,0.5)) * half_angle
		offsets.append(offset)
	return offsets

func attack(direction: Vector2) -> bool:
	if not can_attack(): return false
	aim(direction)
	for offset in generate_pellet_offsets():
		var bullet = BULLET.instantiate()
		bullet.shooter = actor
		bullet.damage = pellet_damage
		bullet.global_position = muzzle.global_position
		bullet.rotation = global_rotation + offset
		get_tree().root.add_child(bullet)
	return true
