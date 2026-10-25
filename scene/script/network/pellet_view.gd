class_name NetworkPelletView
extends Node2D

## Presentation-only replica for host-authoritative shotgun pellets. It creates
## Sprite2D children with no collision objects or damage script; the complete
## authority checkpoint decides their position and lifetime, including while
## they are outside every camera.

const PELLET_SHADER := preload("res://asset/shaders/pellet_fire_rim.gdshader")
const PELLET_TEXTURE_PATH := "res://asset/pic/bullet_standred.png"
const PELLET_REGION := Rect2(384.0, 512.0, 1152.0, 1152.0)
const PELLET_SCALE := Vector2(0.004277778, 0.004277778)

var _bridge: Node
var _sprites: Dictionary = {}

func configure(bridge: Node) -> bool:
	if not is_instance_valid(bridge) or not bridge.has_method("get_combat_state"):
		return false
	_bridge = bridge
	set_process(true)
	return true

func _process(_delta: float) -> void:
	if not is_instance_valid(_bridge):
		return
	var combat: Variant = _bridge.get_combat_state()
	if combat is Dictionary:
		apply_projectiles(combat.get("projectiles", []))

func apply_projectiles(projectiles: Array) -> void:
	var live: Dictionary = {}
	for value: Variant in projectiles:
		if not (value is Dictionary):
			continue
		var projectile: Dictionary = value
		var position_value: Variant = projectile.get("position", null)
		if not (position_value is Vector2) or not (position_value as Vector2).is_finite():
			continue
		var key := _projectile_key(projectile)
		if key.is_empty():
			continue
		live[key] = true
		var sprite: Sprite2D = _sprites.get(key)
		if not is_instance_valid(sprite):
			sprite = _create_sprite(key)
			_sprites[key] = sprite
		sprite.global_position = position_value
		var velocity: Variant = projectile.get("velocity", Vector2.ZERO)
		if velocity is Vector2 and (velocity as Vector2).is_finite() and not (velocity as Vector2).is_zero_approx():
			sprite.global_rotation = (velocity as Vector2).angle()
		_update_lighting(sprite, projectile)
	for key: String in _sprites.keys():
		if live.has(key):
			continue
		var old_sprite: Sprite2D = _sprites[key]
		_sprites.erase(key)
		if is_instance_valid(old_sprite):
			old_sprite.free()

func clear() -> void:
	apply_projectiles([])

func _projectile_key(projectile: Dictionary) -> String:
	var shot_id := int(projectile.get("shot_id", -1))
	var pellet_id := int(projectile.get("pellet_id", -1))
	if shot_id < 0 or pellet_id < 0:
		return ""
	return "%d:%d" % [shot_id, pellet_id]

func _create_sprite(key: String) -> Sprite2D:
	var sprite := Sprite2D.new()
	sprite.name = "Pellet_%s" % key.replace(":", "_")
	sprite.texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
	# Runtime loading keeps the module testable before a fresh clone has built its
	# imported texture cache; a normal project import resolves the asset here.
	sprite.texture = load(PELLET_TEXTURE_PATH) as Texture2D
	sprite.region_enabled = true
	sprite.region_rect = PELLET_REGION
	sprite.scale = PELLET_SCALE
	var material := ShaderMaterial.new()
	material.shader = PELLET_SHADER
	sprite.material = material
	add_child(sprite)
	return sprite

func _update_lighting(sprite: Sprite2D, projectile: Dictionary) -> void:
	var material := sprite.material as ShaderMaterial
	if material == null:
		return
	var origin: Variant = projectile.get("origin", Vector2.ZERO)
	if not (origin is Vector2) or not (origin as Vector2).is_finite():
		return
	var toward := (origin as Vector2) - sprite.global_position
	if toward.is_zero_approx():
		toward = -Vector2.RIGHT.rotated(sprite.global_rotation)
	material.set_shader_parameter("light_direction", toward.rotated(-sprite.global_rotation).normalized())
