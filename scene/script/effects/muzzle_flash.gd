extends Node2D
## One-shot cosmetic burst in world space; never reads input or deals damage.
@export_range(0.02, 0.15, 0.005) var flash_duration: float = 0.07
@export_range(0, 20) var spark_count: int = 7
@export_range(0.1, 0.5, 0.01) var spark_lifetime: float = 0.26
@export_range(1.0, 4.0, 0.5) var pixel_size: float = 1.0
var _age: float = 0.0
var _sparks: Array[Dictionary] = []
var _rng := RandomNumberGenerator.new()
var _shape_variant: int = 0

func _ready() -> void:
	add_to_group("muzzle_flash")
	_rng.randomize()
	_shape_variant = _rng.randi_range(0, 2)
	for i in range(spark_count):
		var velocity := Vector2.RIGHT.rotated(deg_to_rad(_rng.randf_range(-35.0, 35.0))) * _rng.randf_range(65.0, 155.0)
		_sparks.append({"origin": Vector2(_rng.randf_range(1.0, 3.0), _rng.randf_range(-0.5, 0.5)), "velocity": velocity, "life": _rng.randf_range(spark_lifetime * 0.6, spark_lifetime), "size": 1})
	queue_redraw()

func play_at(origin: Vector2, direction: Vector2) -> void:
	global_position = origin
	global_rotation = direction.angle()

func _process(delta: float) -> void:
	if not is_finite(delta) or delta <= 0.0: return
	_age += delta
	if _age >= maxf(flash_duration, spark_lifetime):
		queue_free()
		return
	queue_redraw()

func _draw() -> void:
	if _age < flash_duration:
		_draw_flame()
	for spark in _sparks:
		var life: float = spark.life
		if _age >= life: continue
		var at: Vector2 = spark.origin + spark.velocity * _age
		# World-down drift is converted to the effect's local coordinates.
		at += Vector2.DOWN.rotated(-global_rotation) * (35.0 * _age * _age)
		at = at.snapped(Vector2.ONE)
		var color := Color(1.0, 0.84, 0.27) if _age < life * 0.5 else Color(1.0, 0.39, 0.06)
		if _age < 0.03: color = Color(1.0, 0.97, 0.74)
		var side: float = spark.size if _age < life * 0.7 else 1.0
		draw_rect(Rect2(at, Vector2(side, side)), color)

func _draw_flame() -> void:
	var phase := _age / maxf(0.001, flash_duration)
	var widths := [0, 1, 1, 0, 0]
	var columns := 5 if phase < 0.45 else (3 if phase < 0.75 else 2)
	for x in range(columns):
		var half_width: int = widths[x]
		if _shape_variant == 1 and x == 3: half_width = 1
		if _shape_variant == 2 and x == 2: half_width = 0
		for y in range(-half_width, half_width + 1):
			var color := Color(1.0, 0.38, 0.04)
			if abs(y) < half_width and x < columns - 2: color = Color(1.0, 0.76, 0.16)
			if y == 0 and x < 2 and phase < 0.75: color = Color(1.0, 0.97, 0.74)
			draw_rect(Rect2(Vector2(x, y) * pixel_size, Vector2.ONE * pixel_size), color)
