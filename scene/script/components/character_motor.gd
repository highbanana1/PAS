class_name CharacterMotor
extends Node
@export var speed: float = 150.0
@export var jump_velocity: float = -400.0
@export var dash_speed: float = 360.0
@export var dash_duration: float = 0.2
var body: CharacterBody2D
var can_dash: bool = true
var is_dashing: bool = false
var dash_dir: Vector2 = Vector2.RIGHT
var dash_timer: float = 0.0
var jump_count: int = 1
var _jump_requested: bool = false
var _dash_requested: bool = false
var _requested_direction: Vector2

func configure(owner_body: CharacterBody2D) -> void:
	body = owner_body

func request_jump() -> void:
	_jump_requested = true

func request_dash(direction: Vector2) -> void:
	_dash_requested = true
	_requested_direction = direction.normalized()

func tick(delta: float, move_input: Vector2) -> void:
	if not is_instance_valid(body) or body.get("is_dead") == true:
		_jump_requested = false
		_dash_requested = false
		return
	if not body.is_on_floor() and not is_dashing:
		body.velocity += body.get_gravity() * delta
	if body.is_on_floor():
		if jump_count == 0: jump_count = 1
		if not is_dashing and not can_dash: can_dash = true
	if _jump_requested and jump_count != 0:
		body.velocity.y = jump_velocity
		jump_count -= 1
	_jump_requested = false
	if not is_dashing:
		body.velocity.x = move_input.x * speed if move_input.x else move_toward(body.velocity.x, 0.0, speed)
	var direction := move_input.normalized()
	if direction.x != 0.0: dash_dir.x = direction.x
	if _dash_requested and can_dash:
		var final_direction := dash_dir
		if _requested_direction.x != 0.0: final_direction.x = _requested_direction.x
		if _requested_direction.y != 0.0 and _requested_direction.x == 0.0: final_direction.x = 0.0
		final_direction.y = _requested_direction.y
		can_dash = false
		is_dashing = true
		dash_timer = dash_duration
		body.velocity = final_direction * dash_speed
	_dash_requested = false
	if is_dashing:
		dash_timer -= delta
		if dash_timer <= 0.0: is_dashing = false

func reset_state() -> void:
	can_dash = true
	is_dashing = false
	dash_dir = Vector2.RIGHT
	dash_timer = 0.0
	jump_count = 1
	_jump_requested = false
	_dash_requested = false
	if is_instance_valid(body): body.velocity = Vector2.ZERO
