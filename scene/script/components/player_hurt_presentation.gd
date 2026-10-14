class_name PlayerHurtPresentation
extends Node2D
const Context = preload("res://scene/script/combat/attack_context.gd")
@export var flash_duration: float = 0.07
@export var lean_duration: float = 0.18
@export var animation_duration: float = 0.42
@export var lean_angle: float = 12.0
var is_playing: bool = false
var _actor: Node2D
var _receiver: Node
var _sprite: AnimatedSprite2D
var _rest_material: Material
var _rest_rotation: float
var _rest_color: Color
var _flash_material: ShaderMaterial
var _age: float = 0.0
var _lean_sign: float = -1.0

func configure(actor: Node2D, receiver: Node, sprite: AnimatedSprite2D) -> void:
	if is_instance_valid(_receiver) and _receiver.attack_received.is_connected(_on_attack_received):
		_receiver.attack_received.disconnect(_on_attack_received)
	if is_instance_valid(_actor) and _actor.has_signal("character_died") and _actor.character_died.is_connected(reset_state):
		_actor.character_died.disconnect(reset_state)
	reset_state()
	_actor = actor
	_receiver = receiver
	_sprite = sprite
	_rest_material = sprite.material
	_rest_rotation = sprite.rotation
	_rest_color = sprite.self_modulate
	var shader := Shader.new()
	shader.code = "shader_type canvas_item; uniform float flash_amount = 0.0; void fragment() { COLOR.rgb = mix(COLOR.rgb, vec3(1.0), flash_amount); }"
	_flash_material = ShaderMaterial.new()
	_flash_material.shader = shader
	_receiver.attack_received.connect(_on_attack_received)
	if _actor.has_signal("character_died"): _actor.character_died.connect(reset_state)
	z_index = 40
	texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
	hide()

func _on_attack_received(context: RefCounted, result: int) -> void:
	if result != Context.Result.DAMAGED or not is_instance_valid(_actor) or _actor.get("is_dead") == true: return
	if not is_instance_valid(_sprite): return
	var away: Vector2 = _actor.global_position - context.origin
	_lean_sign = signf(away.x) if not is_zero_approx(away.x) else (1.0 if _sprite.flip_h else -1.0)
	_age = 0.0
	is_playing = true
	_sprite.material = _flash_material
	_flash_material.set_shader_parameter("flash_amount", 1.0)
	_sprite.rotation = _rest_rotation + _lean_sign * deg_to_rad(lean_angle)
	_sprite.self_modulate = _rest_color
	global_position = _actor.global_position
	show()
	queue_redraw()

func _process(delta: float) -> void:
	if not is_playing: return
	if not is_instance_valid(_actor) or not is_instance_valid(_sprite) or _actor.get("is_dead") == true:
		reset_state()
		return
	_age += delta
	if _age >= animation_duration:
		reset_state()
		return
	global_position = _actor.global_position
	_flash_material.set_shader_parameter("flash_amount", 1.0 if _age < flash_duration else 0.0)
	var lean := pow(maxf(1.0 - _age / maxf(lean_duration, 0.001), 0.0), 2.0)
	_sprite.rotation = _rest_rotation + _lean_sign * deg_to_rad(lean_angle) * lean
	var color := _rest_color
	if _age >= flash_duration and int((_age - flash_duration) / 0.07) % 2 == 1: color.a *= 0.22
	_sprite.self_modulate = color
	queue_redraw()

func reset_state() -> void:
	if is_playing and is_instance_valid(_sprite):
		_sprite.material = _rest_material
		_sprite.rotation = _rest_rotation
		_sprite.self_modulate = _rest_color
	is_playing = false
	hide()
	queue_redraw()

func _draw() -> void:
	if not is_playing or _age >= 0.12: return
	var scale_factor := maxf(absf(global_scale.x), 0.001)
	var progress := clampf(_age / 0.12, 0.0, 1.0)
	for index in range(8):
		var direction := Vector2.from_angle(index * TAU / 8.0 + PI / 8.0)
		var start := direction * (5.0 + progress * 5.0) / scale_factor
		var end := direction * (16.0 + progress * 4.0) / scale_factor
		draw_line(start, end, Color(0.02, 0.02, 0.03, 1.0 - progress), 4.0 / scale_factor)
		draw_line(start, end, Color(1.0, 1.0, 1.0, 1.0 - progress), 1.5 / scale_factor)

func _exit_tree() -> void:
	reset_state()
