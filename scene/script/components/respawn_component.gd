class_name RespawnComponent
extends Node
signal died()
signal countdown_changed(seconds: float)
signal respawn_requested(position: Vector2)
var dead: bool = false
var spawn_position: Vector2
var delay: float = 5.0
var _timer: Timer
var time_left: float:
	get: return _timer.time_left if is_instance_valid(_timer) else 0.0

func configure(timer: Timer, spawn: Vector2, respawn_delay: float) -> void:
	if is_instance_valid(_timer) and _timer.timeout.is_connected(_on_timeout):
		_timer.timeout.disconnect(_on_timeout)
	_timer = timer
	_timer.one_shot = true
	_timer.timeout.connect(_on_timeout)
	spawn_position = spawn
	delay = respawn_delay

func die() -> bool:
	if dead: return false
	assert(is_instance_valid(_timer), "Configure RespawnComponent with a Timer before dying")
	dead = true
	_timer.start(maxf(delay, 0.05))
	died.emit()
	countdown_changed.emit(time_left)
	return true

func respawn(position: Vector2) -> bool:
	if not dead: return false
	_timer.stop()
	dead = false
	respawn_requested.emit(position)
	return true

func reset_spawn(position: Vector2) -> void:
	spawn_position = position

func _physics_process(_delta: float) -> void:
	if dead: countdown_changed.emit(time_left)

func _on_timeout() -> void:
	respawn(spawn_position)
