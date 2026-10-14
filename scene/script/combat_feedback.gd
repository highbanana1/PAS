extends Node2D
## Short-lived presentation only: never changes combat, pause state, or time scale.

const HIT_DURATION := 0.14
const GUARD_DURATION := 0.18
var kind: String = "hit"
var _age: float = 0.0
var _duration: float = HIT_DURATION
var _direction: Vector2 = Vector2.RIGHT
var _target: WeakRef
var _flash: Sprite2D


static func spawn_hit(target: Node2D, point: Vector2, source: AnimatedSprite2D = null) -> void:
	var effect = load("res://scene/script/combat_feedback.gd").new()
	effect.kind = "hit"
	target.get_tree().root.add_child(effect)
	effect.global_position = point
	if source == null: source = target.get_node_or_null("AnimatedSprite2D") as AnimatedSprite2D
	if source != null and source.sprite_frames != null:
		effect._target = weakref(source)
		effect._flash = Sprite2D.new()
		effect._flash.texture = source.sprite_frames.get_frame_texture(source.animation, source.frame)
		effect._flash.centered = source.centered
		effect._flash.offset = source.offset
		effect._flash.flip_h = source.flip_h
		effect._flash.flip_v = source.flip_v
		var shader := Shader.new()
		shader.code = "shader_type canvas_item; render_mode unshaded; void fragment() { COLOR = vec4(vec3(1.0), texture(TEXTURE, UV).a * COLOR.a); }"
		var material := ShaderMaterial.new()
		material.shader = shader
		effect._flash.material = material
		effect.add_child(effect._flash)
		effect._flash.global_transform = source.global_transform


static func spawn_guard(player: Node2D, direction: Vector2) -> void:
	var effect = load("res://scene/script/combat_feedback.gd").new()
	effect.kind = "guard"
	effect._duration = GUARD_DURATION
	effect._direction = direction
	player.get_tree().root.add_child(effect)
	effect.global_position = player.global_position + direction * 15.0


func _ready() -> void:
	add_to_group("combat_feedback")
	z_index = 40
	texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST


func _process(delta: float) -> void:
	_age += delta
	if _age >= _duration:
		queue_free()
		return
	if _flash != null:
		var source = _target.get_ref()
		if is_instance_valid(source):
			_flash.global_transform = source.global_transform
			_flash.texture = source.sprite_frames.get_frame_texture(source.animation, source.frame)
			_flash.flip_h = source.flip_h
			_flash.flip_v = source.flip_v
		_flash.modulate.a = pow(1.0 - _age / _duration, 2.0)
	queue_redraw()


func _draw() -> void:
	var progress := clampf(_age / _duration, 0.0, 1.0)
	var color := Color(0.65, 0.9, 1.0, 1.0 - progress) if kind == "guard" else Color(1.0, 0.95, 0.72, 1.0 - progress)
	for index in range(6):
		var angle := index * TAU / 6.0
		var direction := Vector2.from_angle(angle)
		if kind == "guard":
			direction = Vector2.from_angle(_direction.angle() + (index - 2.5) * 0.55)
		var start := direction * (2.0 + progress * 7.0)
		var finish := start + direction * (5.0 * (1.0 - progress))
		draw_line(start.round(), finish.round(), color, 1.5)
	if progress < 0.4:
		draw_rect(Rect2(-1.5, -1.5, 3.0, 3.0), Color(1.0, 1.0, 1.0, 1.0 - progress))


static func show_hit(target: Node2D, point: Vector2) -> void:
	spawn_hit(target, point)

static func show_block(actor: Node2D, direction: Vector2) -> void:
	spawn_guard(actor, direction)
