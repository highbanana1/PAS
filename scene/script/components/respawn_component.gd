class_name RespawnComponent
extends Node
signal died()
signal countdown_changed(seconds: float)
signal respawn_requested(position: Vector2)
var dead: bool = false
var spawn_position: Vector2
var delay: float = 5.0
var authority_managed: bool = false
var authority_remaining: float = 0.0
var _timer: Timer
var time_left: float:
	get:
		if authority_managed: return authority_remaining
		return _timer.time_left if is_instance_valid(_timer) else 0.0

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
	if authority_managed:
		authority_remaining = maxf(delay, 0.05)
	else:
		_timer.start(maxf(delay, 0.05))
	died.emit()
	countdown_changed.emit(time_left)
	return true

func respawn(position: Vector2) -> bool:
	if not dead: return false
	if is_instance_valid(_timer): _timer.stop()
	dead = false
	authority_remaining = 0.0
	respawn_requested.emit(position)
	return true

## Authority-managed countdowns keep the same lifecycle signals and UI while
## MatchAuthority owns the fixed-step timer. The real Timer stays as the
## compatibility path for actors that are not bound to an authority.
func set_authority_managed(enabled: bool) -> void:
	if authority_managed == enabled: return
	if enabled and dead:
		var pending := _timer.time_left if is_instance_valid(_timer) and _timer.time_left > 0.0 else authority_remaining
		authority_remaining = maxf(pending, 0.05)
		if is_instance_valid(_timer): _timer.stop()
	elif not enabled and dead:
		if is_instance_valid(_timer): _timer.start(maxf(authority_remaining, 0.05))
		authority_remaining = 0.0
	authority_managed = enabled

func set_authority_remaining(seconds: float) -> void:
	if not authority_managed: return
	authority_remaining = maxf(seconds, 0.0)
	if dead: countdown_changed.emit(authority_remaining)

func reset_spawn(position: Vector2) -> void:
	spawn_position = position

func _physics_process(_delta: float) -> void:
	if dead: countdown_changed.emit(time_left)

func _on_timeout() -> void:
	if not authority_managed: respawn(spawn_position)
