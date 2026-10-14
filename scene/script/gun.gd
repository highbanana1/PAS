extends "res://scene/script/weapons/weapon_base.gd"
const BULLET = preload("res://scene/bullet.tscn")
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

func attack(direction: Vector2) -> bool:
	if not can_attack(): return false
	aim(direction)
	var bullet = BULLET.instantiate()
	bullet.shooter = actor
	bullet.global_position = muzzle.global_position
	bullet.rotation = global_rotation
	get_tree().root.add_child(bullet)
	return true
