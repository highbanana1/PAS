extends Node2D
## Cosmetic pump/cooldown component for a shotgun.
## Controls only its own local position/rotation and the Pump child's position.
## Owns one per-weapon cycle clock; never reads input or affects other actors.

const DEFAULT_CYCLE_DURATION := 0.65
const MIN_CYCLE_DURATION := 0.05

## Snapped recoil offset in local units (multiples of 16).
const RECOIL_OFFSET_X := -48.0
const RECOIL_ROTATION := -0.04

## Pump travel distance in local units (multiple of 16).
const PUMP_TRAVEL_X := 96.0

## Normalized phase boundaries for the pump cycle.
const KICK_END := 0.15
const PUMP_REST_END := 0.18
const PUMP_BACK_END := 0.5
const PUMP_PAUSE_END := 0.6
const PUMP_FORWARD_END := 0.92

var _visual_enabled: bool = true
@onready var _pump: Sprite2D = $Pump

## Rest pose captured in _ready.
var _rest_body_position: Vector2
var _rest_body_rotation: float
var _rest_pump_position: Vector2

## Remaining cycle time in seconds. 0 when idle.
var remaining: float = 0.0

## Duration of the current cycle.
var cycle_duration: float = DEFAULT_CYCLE_DURATION


func _ready() -> void:
	_rest_body_position = position
	_rest_body_rotation = rotation
	_rest_pump_position = _pump.position
	_apply_rest_pose()


func _process(delta: float) -> void:
	tick(delta)


## Begins a new pump cycle. Rejects if already busy.
## Returns true if the cycle started successfully.
func begin_cycle(duration: float) -> bool:
	if is_busy():
		return false
	var normalized := duration
	if not is_finite(normalized) or normalized <= 0.0:
		normalized = DEFAULT_CYCLE_DURATION
	normalized = maxf(normalized, MIN_CYCLE_DURATION)
	cycle_duration = normalized
	remaining = normalized
	_visual_enabled = true
	_apply_phase(0.0)
	return true


## Advances the cycle by delta seconds. Invalid or negative delta is ignored.
func tick(delta: float) -> void:
	if not is_busy():
		return
	if not is_finite(delta) or delta <= 0.0:
		return
	remaining -= delta
	if remaining <= 0.0:
		remaining = 0.0
		_apply_rest_pose()
	else:
		var elapsed: float = cycle_duration - remaining
		var phase: float = clampf(elapsed / cycle_duration, 0.0, 1.0)
		if _visual_enabled: _apply_phase(phase)


func is_busy() -> bool:
	return remaining > 0.0


## Restores exact rest pose without clearing timing state.
## Processing remains active so the cycle can continue while hidden or remote.
func cancel_visual() -> void:
	_visual_enabled = false
	_apply_rest_pose()


## Reapplies the current visual phase. Does nothing when idle.
func resume_visual() -> void:
	_visual_enabled = true
	if not is_busy():
		return
	var elapsed: float = cycle_duration - remaining
	var phase: float = clampf(elapsed / cycle_duration, 0.0, 1.0)
	_apply_phase(phase)


## Clears all timing and restores exact rest pose.
func reset_state() -> void:
	_visual_enabled = true
	remaining = 0.0
	cycle_duration = DEFAULT_CYCLE_DURATION
	_apply_rest_pose()


## Applies the exact rest pose from _ready.
func _apply_rest_pose() -> void:
	position = _rest_body_position
	rotation = _rest_body_rotation
	_pump.position = _rest_pump_position


## Applies the visual state for a normalized phase in [0, 1].
## Recoil kicks in immediately and returns by phase 0.15.
## Pump rests until 0.18, slides back to 0.5, pauses to 0.6,
## slides forward to 0.92, then settles.
func _apply_phase(phase: float) -> void:
	var p: float = clampf(phase, 0.0, 1.0)

	# Recoil: kick out fast, ease back to rest by KICK_END.
	if p <= 0.0:
		position.x = _rest_body_position.x
		rotation = _rest_body_rotation
	elif p < KICK_END:
		var t: float = p / KICK_END
		# Fast kick out, smooth return within the kick window.
		var recoil_t: float = sin(t * PI)  # 0 -> 1 -> 0
		position.x = _rest_body_position.x + snappedf(RECOIL_OFFSET_X * recoil_t, 16.0)
		rotation = _rest_body_rotation + RECOIL_ROTATION * recoil_t
	else:
		position.x = _rest_body_position.x
		rotation = _rest_body_rotation

	# Pump slide along x only. y stays at rest.
	var pump_x: float = _rest_pump_position.x
	if p <= PUMP_REST_END:
		pump_x = _rest_pump_position.x
	elif p <= PUMP_BACK_END:
		var t: float = (p - PUMP_REST_END) / (PUMP_BACK_END - PUMP_REST_END)
		var eased: float = _ease_in_out(t)
		pump_x = _rest_pump_position.x - PUMP_TRAVEL_X * eased
	elif p <= PUMP_PAUSE_END:
		pump_x = _rest_pump_position.x - PUMP_TRAVEL_X
	elif p <= PUMP_FORWARD_END:
		var t: float = (p - PUMP_PAUSE_END) / (PUMP_FORWARD_END - PUMP_PAUSE_END)
		var eased: float = _ease_in_out(t)
		pump_x = _rest_pump_position.x - PUMP_TRAVEL_X * (1.0 - eased)
	else:
		pump_x = _rest_pump_position.x

	# Snap pump x to multiples of 16 while preserving exact rest at endpoints.
	if p > 0.0 and p < 1.0:
		pump_x = snappedf(pump_x, 16.0)
	_pump.position = Vector2(pump_x, _rest_pump_position.y)


func _ease_in_out(t: float) -> float:
	var clamped: float = clampf(t, 0.0, 1.0)
	return clamped * clamped * (3.0 - 2.0 * clamped)
