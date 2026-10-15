extends Node2D
const Context = preload("res://scene/script/combat/attack_context.gd")
const Receiver = preload("res://scene/script/combat/combat_receiver.gd")

const SPEED= 700
var shooter: Node2D = null
@export var damage: int = 1
## Gentle world-down acceleration; zero restores straight flight.
@export_range(0.0, 200.0, 1.0, "or_greater", "suffix:px/s²") var gravity_strength: float = 35.0
@export_range(0.5, 1.5, 0.01) var speed_multiplier: float = 1.0
var _fall_speed: float = 0.0
var _fire_light_origin: Vector2
var _has_fire_light_origin: bool = false
var _light_material: ShaderMaterial

# Called when the node enters the scene tree for the first time.
func _ready() -> void:
	if $Sprite2D.material is ShaderMaterial:
		_light_material = $Sprite2D.material.duplicate() as ShaderMaterial
		$Sprite2D.material = _light_material
		_update_fire_lighting()


# Called every frame. 'delta' is the elapsed time since the previous frame.
func _process(delta: float) -> void:
	if not is_finite(delta) or delta <= 0.0: return
	position += transform.x * SPEED * speed_multiplier * delta + Vector2.DOWN * (_fall_speed * delta + 0.5 * gravity_strength * delta * delta)
	_fall_speed += gravity_strength * delta
	_update_fire_lighting()
	


func _on_visible_on_screen_notifier_2d_screen_exited() -> void:
	queue_free()


func _on_area_2d_area_entered(area: Area2D) -> void:
	pass


func _on_area_2d_body_entered(body: Node2D) -> void:
	if is_queued_for_deletion():
		return
	if is_instance_valid(shooter) and body == shooter:
		return
	# Capture incoming direction, independent of the shooter's later position.
	var attack_origin := global_position - global_transform.x.normalized() * 64.0
	Receiver.deliver(body, Context.new(damage, attack_origin, shooter, true))
	queue_free()
func die()->void:
	queue_free()

func set_fire_light_origin(origin: Vector2) -> void:
	if not origin.is_finite(): return
	_fire_light_origin = origin
	_has_fire_light_origin = true
	_update_fire_lighting()

func _update_fire_lighting() -> void:
	if _light_material == null or not _has_fire_light_origin: return
	var toward := _fire_light_origin - global_position
	if toward.is_zero_approx(): toward = -global_transform.x
	var local_direction := global_transform.basis_xform_inv(toward).normalized()
	_light_material.set_shader_parameter("light_direction", local_direction)
