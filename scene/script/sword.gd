extends "res://scene/script/weapons/weapon_base.gd"
const Context = preload("res://scene/script/combat/attack_context.gd")
const Receiver = preload("res://scene/script/combat/combat_receiver.gd")

@export var damage: int = 2
@export var attack_range: float = 36.0
@export_range(10.0, 170.0) var swing_angle: float = 120.0
@export var windup_duration: float = 0.045
@export var swing_duration: float = 0.09
@export var recovery_duration: float = 0.11
@export var attack_cooldown: float = 0.245

var is_swinging: bool = false
var _swing_direction: Vector2 = Vector2.RIGHT
var _swing_elapsed: float = 0.0
var _cooldown_left: float = 0.0
var _hit_targets: Dictionary = {}
var _guard_visible: bool = false
var _guard_direction: Vector2 = Vector2.RIGHT
func _init() -> void:
	supports_guard = true

func attack(direction: Vector2) -> bool:
	return start_swing(direction)

func is_busy() -> bool:
	return is_swinging

func reset_state() -> void:
	reset_combat_state()


func start_swing(direction: Vector2) -> bool:
	if not can_attack() or (is_instance_valid(controller) and controller.is_guarding) or is_swinging or _cooldown_left > 0:
		return false
	_swing_direction = direction.normalized() if not direction.is_zero_approx() else Vector2.RIGHT
	_swing_elapsed = 0.0
	_cooldown_left = attack_cooldown
	_hit_targets.clear()
	is_swinging = true
	_update_pose()
	queue_redraw()
	return true


func _process(_delta: float) -> void:
	if not active or (not is_instance_valid(actor) or actor.get("is_dead") == true):
		return
	_update_pose()
	queue_redraw()


func _update_pose() -> void:
	if is_swinging:
		var half_angle := deg_to_rad(swing_angle * 0.5)
		var offset: float
		if _swing_elapsed < windup_duration:
			var progress := _swing_elapsed / maxf(windup_duration, 0.001)
			offset = lerpf(-half_angle + 0.2, -half_angle, smoothstep(0.0, 1.0, progress))
		elif _swing_elapsed < windup_duration + swing_duration:
			offset = lerpf(-half_angle, half_angle, _sweep_progress(_swing_elapsed))
		else:
			var progress := (_swing_elapsed - windup_duration - swing_duration) / maxf(recovery_duration, 0.001)
			global_rotation = lerp_angle(_swing_direction.angle() + half_angle, aim_direction.angle(), smoothstep(0.0, 1.0, progress))
			return
		global_rotation = _swing_direction.angle() + offset
	elif _guard_visible:
		global_rotation = _guard_direction.angle() + PI * 0.5
	else:
		global_rotation = aim_direction.angle()


func _sweep_progress(elapsed: float) -> float:
	var progress := clampf((elapsed - windup_duration) / maxf(swing_duration, 0.001), 0.0, 1.0)
	return 1.0 - pow(1.0 - progress, 2.0)


func _physics_process(delta: float) -> void:
	_cooldown_left = maxf(_cooldown_left - delta, 0.0)
	if not active or not is_swinging or (not is_instance_valid(actor) or actor.get("is_dead") == true):
		return
	var previous := _swing_elapsed
	_swing_elapsed += delta
	# Sweep the interval the blade actually travelled, including skipped frames.
	if _swing_elapsed >= windup_duration and previous < windup_duration + swing_duration:
		_hit_sector(_sweep_progress(previous), _sweep_progress(_swing_elapsed))
	if _swing_elapsed >= windup_duration + swing_duration + recovery_duration:
		is_swinging = false
	_update_pose()
	queue_redraw()


func _hit_sector(previous: float, current: float) -> void:
	var points := PackedVector2Array([Vector2.ZERO])
	var half_angle := deg_to_rad(swing_angle * 0.5)
	var start := lerpf(-half_angle, half_angle, previous) - deg_to_rad(5.0)
	var finish := lerpf(-half_angle, half_angle, current) + deg_to_rad(5.0)
	for step in range(13):
		points.append(Vector2.from_angle(lerpf(start, finish, step / 12.0)) * attack_range)
	var sector := ConvexPolygonShape2D.new()
	sector.points = points
	var query := PhysicsShapeQueryParameters2D.new()
	query.shape = sector
	query.transform = Transform2D(_swing_direction.angle(), global_position)
	query.collision_mask = 2 | 8
	query.exclude = [actor.get_rid()] if actor is CollisionObject2D else []
	query.collide_with_areas = false
	for hit in get_world_2d().direct_space_state.intersect_shape(query, 32):
		var target = hit["collider"]
		if not is_instance_valid(target) or _hit_targets.has(target.get_instance_id()):
			continue
		if not target.is_in_group("enemy") and not target.is_in_group("player"):
			continue
		var ray := PhysicsRayQueryParameters2D.create(global_position, target.global_position, 1)
		if not get_world_2d().direct_space_state.intersect_ray(ray).is_empty():
			continue
		_hit_targets[target.get_instance_id()] = true
		var result: int = Receiver.deliver(target, Context.new(damage, global_position, actor, true))
		attack_resolved.emit(target, result)


func set_guard_visual(enabled: bool, direction: Vector2) -> void:
	_guard_visible = enabled
	_guard_direction = direction
	queue_redraw()


func cancel_attack() -> void:
	is_swinging = false
	_hit_targets.clear()
	queue_redraw()


func reset_combat_state() -> void:
	cancel_attack()
	_cooldown_left = 0.0


func _draw() -> void:
	var scale_factor := maxf(absf(global_scale.x), 0.001)
	var since_sweep := _swing_elapsed - windup_duration
	if is_swinging and since_sweep >= 0.0 and since_sweep < swing_duration + 0.045:
		var progress := _sweep_progress(_swing_elapsed)
		var fade := 1.0 - clampf((since_sweep - swing_duration) / 0.045, 0.0, 1.0)
		var end := _swing_direction.angle() - global_rotation + deg_to_rad(swing_angle) * (progress - 0.5)
		var start := end - deg_to_rad(minf(50.0, swing_angle * progress))
		# Compact tapering blade trail, rather than a persistent whole fan.
		for section in range(5):
			var a := lerpf(start, end, section / 5.0)
			var b := lerpf(start, end, (section + 1) / 5.0)
			var strength := (section + 1) / 5.0
			draw_arc(Vector2.ZERO, attack_range * 0.83 / scale_factor, a, b, 4, Color(0.7, 0.94, 1.0, strength * fade), (1.0 + strength * 2.0) / scale_factor)
	if _guard_visible:
		var facing := _guard_direction.angle() - global_rotation
		draw_arc(Vector2.ZERO, 16.0 / scale_factor, facing - deg_to_rad(70), facing + deg_to_rad(70), 8, Color(0.2, 0.65, 1.0, 0.9), 2.0 / scale_factor)
