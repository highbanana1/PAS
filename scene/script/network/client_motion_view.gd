class_name ClientMotionView
extends RefCounted

## Ticket 02B2B client presentation seam. It owns two visual-only concerns:
##
##  * Local movement prediction. Every submitted input is kept with its stable
##    NetworkSession sequence. A predicted local position advances at the
##    CharacterMotor speed; an authoritative snapshot resets the simulation to
##    the authoritative checkpoint, replays only inputs whose sequence is still
##    unacknowledged, and either smooths a small error or hard-snaps a large /
##    discontinuous one. Acknowledged sequences are dropped exactly once.
##  * Remote interpolation. Strictly increasing server-tick samples are kept in
##    a bounded buffer and sampled at a render tick that trails the newest
##    authoritative tick. Missing, duplicate, regressed, teleport and
##    death/respawn cases clamp or snap instead of extrapolating.
##
## This module never owns gameplay state and has no reference to MatchAuthority.
## Its only output is render state consumed by the bridge's actor presentation.

const FIXED_STEP: float = 1.0 / 60.0
const PREDICTION_SPEED: float = 150.0
const EPSILON: float = 0.000001
const SNAP_EPSILON: float = 0.05
const SMOOTH_RATE: float = 14.0
const MAX_CORRECTION_SPEED: float = 480.0
const LARGE_ERROR_THRESHOLD: float = 48.0
const TELEPORT_THRESHOLD: float = 120.0
const MAX_PENDING_INPUTS: int = 64
const MAX_REMOTE_SAMPLES: int = 32
const REMOTE_DELAY_TICKS: float = 6.0
const RENDER_TICK_RATE: float = 60.0
const MAX_REMOTE_LAG_TICKS: float = 30.0
const MAX_LOCAL_STEPS_PER_TICK: int = 8

const FALLBACK_DEATH: String = "death"
const FALLBACK_RESPAWN: String = "respawn"
const FALLBACK_TELEPORT: String = "teleport"
const FALLBACK_LARGE_ERROR: String = "large_error"
const FALLBACK_EPOCH_CHANGED: String = "epoch_changed"
const FALLBACK_PENDING_OVERFLOW: String = "pending_overflow"
const FALLBACK_INPUT_EXPIRED: String = "input_expired"
const FALLBACK_REMOTE_LAG: String = "remote_lag"
## An unacknowledged input older than this many authority ticks can no longer
## be replayed safely: the transport may have dropped it. Presentation falls
## back to the authoritative checkpoint instead of drifting forever.
const MAX_INPUT_AGE_TICKS: int = 60
const FALLBACK_REMOTE_TELEPORT: String = "remote_teleport"
const FALLBACK_REMOTE_LIFE_STATE: String = "remote_life_state"
const FALLBACK_REMOTE_REVISION: String = "remote_revision_regressed"

var _active: bool = false
var _match_epoch: int = 0
var _movement_speed: float = PREDICTION_SPEED

var _local_player_id: StringName = &""
var _local_ready: bool = false
var _local_alive: bool = true
var _local_auth_position: Vector2 = Vector2.ZERO
var _local_auth_tick: int = -1
var _local_auth_state: Dictionary = {}
var _local_sim_position: Vector2 = Vector2.ZERO
var _local_render_position: Vector2 = Vector2.ZERO
var _local_direction: Vector2 = Vector2.ZERO
var _local_last_ack: int = -1
var _local_step_accumulator: float = 0.0
var _pending_inputs: Array = []
var _corrections: int = 0
var _large_corrections: int = 0
var _fallbacks: int = 0
var _injected_errors: int = 0
var _last_fallback_reason: String = ""
var _last_reconcile: Dictionary = {}

var _remote_samples: Dictionary = {}
var _remote_render_states: Dictionary = {}
var _remote_interpolated_frames: Dictionary = {}
var _remote_rejected: Dictionary = {}
var _remote_snap_events: Dictionary = {}
var _remote_fallback_reasons: Dictionary = {}
var _remote_render_tick: float = 0.0
var _remote_newest_tick: int = -1
var _remote_has_clock: bool = false
var _remote_snap_total: int = 0

func configure(match_epoch: int) -> void:
	_match_epoch = match_epoch
	_active = true
	_movement_speed = PREDICTION_SPEED
	_local_player_id = &""
	_local_ready = false
	_local_alive = true
	_local_auth_position = Vector2.ZERO
	_local_auth_tick = -1
	_local_auth_state.clear()
	_local_sim_position = Vector2.ZERO
	_local_render_position = Vector2.ZERO
	_local_direction = Vector2.ZERO
	_local_last_ack = -1
	_local_step_accumulator = 0.0
	_pending_inputs.clear()
	_corrections = 0
	_large_corrections = 0
	_fallbacks = 0
	_injected_errors = 0
	_last_fallback_reason = ""
	_last_reconcile = {}
	_remote_samples.clear()
	_remote_render_states.clear()
	_remote_interpolated_frames.clear()
	_remote_rejected.clear()
	_remote_snap_events.clear()
	_remote_fallback_reasons.clear()
	_remote_render_tick = 0.0
	_remote_newest_tick = -1
	_remote_has_clock = false
	_remote_snap_total = 0

func deactivate(reason: String = "deactivated") -> void:
	if not _active:
		return
	_active = false
	_pending_inputs.clear()
	_local_direction = Vector2.ZERO
	_local_ready = false
	_local_alive = true
	_local_auth_position = Vector2.ZERO
	_local_auth_tick = -1
	_local_auth_state.clear()
	_local_sim_position = Vector2.ZERO
	_local_render_position = Vector2.ZERO
	_local_step_accumulator = 0.0
	_local_last_ack = -1
	_remote_samples.clear()
	_remote_render_states.clear()
	_remote_interpolated_frames.clear()
	_remote_rejected.clear()
	_remote_snap_events.clear()
	_remote_fallback_reasons.clear()
	_remote_render_tick = 0.0
	_remote_newest_tick = -1
	_remote_has_clock = false
	_last_fallback_reason = reason

func is_active() -> bool:
	return _active

func is_ready() -> bool:
	return _active and _local_ready

func set_local_player(player_id: StringName) -> void:
	if player_id == &"":
		return
	if _local_player_id == player_id:
		return
	_local_player_id = player_id
	_local_ready = false
	_local_alive = true
	_local_auth_tick = -1
	_local_auth_state.clear()
	_local_last_ack = -1
	_local_sim_position = Vector2.ZERO
	_local_render_position = Vector2.ZERO
	_local_step_accumulator = 0.0
	_pending_inputs.clear()
	_local_direction = Vector2.ZERO

func get_local_player_id() -> StringName:
	return _local_player_id

func get_match_epoch() -> int:
	return _match_epoch

## Presentation speed must track the real actor's CharacterMotor speed. The
## caller passes the bound motor's exported speed; invalid values are ignored.
func set_movement_speed(speed: float) -> bool:
	if is_nan(speed) or is_inf(speed) or speed <= 0.0:
		return false
	_movement_speed = speed
	return true

func get_movement_speed() -> float:
	return _movement_speed

## Installs the reliable full baseline. The local checkpoint is authoritative and
## every prediction buffer is cleared; remote buffers restart from this exact
## tick. Returns false for inactive or stale-epoch input. An epoch mismatch is
## cleaned up as a presentation reset because the view must be reconfigured for
## the new epoch, but it never mutates gameplay state.
func apply_baseline(baseline: Dictionary) -> bool:
	if not _active:
		return false
	var epoch := int(baseline.get("match_epoch", -1))
	# A client provisions the bridge before its identity arrives, so the session
	# epoch is still 0. The authoritative baseline carries the real epoch; adopt
	# it once instead of silently rejecting every later snapshot.
	if _match_epoch <= 0 and epoch > 0:
		_match_epoch = epoch
	if epoch != _match_epoch:
		_reset_epoch_presentation(FALLBACK_EPOCH_CHANGED)
		return false
	var tick := int(baseline.get("baseline_tick", baseline.get("server_tick", -1)))
	if tick < 0:
		return false
	var players_variant: Variant = baseline.get("players", null)
	if not (players_variant is Dictionary):
		return false
	_reset_local_checkpoint()
	_remote_samples.clear()
	_remote_render_states.clear()
	_remote_interpolated_frames.clear()
	_remote_rejected.clear()
	_remote_snap_events.clear()
	_remote_fallback_reasons.clear()
	_remote_render_tick = float(tick) - REMOTE_DELAY_TICKS
	_remote_newest_tick = tick
	_remote_has_clock = true
	var players: Dictionary = players_variant
	for raw_id: Variant in players:
		var state_variant: Variant = players[raw_id]
		if not (state_variant is Dictionary):
			continue
		var state: Dictionary = state_variant
		var player_id := StringName(String(state.get("player_id", raw_id)))
		if player_id == &"":
			continue
		if player_id == _local_player_id:
			_install_local_baseline(state, tick)
		else:
			_push_remote_sample(player_id, state, tick, true)
	return true

## Applies one strictly newer authoritative snapshot to the presentation layer.
## The authoritative replica already rejected stale/regressed batches upstream;
## this method only needs to keep presentation state safe. Remotes absent from a
## complete roster snapshot are pruned so a departed player cannot be rendered
## from stale samples.
func apply_snapshot(batch: Dictionary) -> bool:
	if not _active:
		return false
	if int(batch.get("match_epoch", -1)) != _match_epoch:
		_reset_epoch_presentation(FALLBACK_EPOCH_CHANGED)
		return false
	var tick := int(batch.get("server_tick", -1))
	if tick < 0:
		return false
	var players_variant: Variant = batch.get("players", null)
	if not (players_variant is Dictionary):
		return false
	var players: Dictionary = players_variant
	var seen: Dictionary = {}
	for raw_id: Variant in players:
		var state_variant: Variant = players[raw_id]
		if not (state_variant is Dictionary):
			continue
		var state: Dictionary = state_variant
		var player_id := StringName(String(state.get("player_id", raw_id)))
		if player_id == &"":
			continue
		seen[String(player_id)] = true
		if player_id == _local_player_id:
			_reconcile_local(state, tick)
		else:
			_push_remote_sample(player_id, state, tick, false)
	_prune_absent_remotes(seen)
	_remote_newest_tick = maxi(_remote_newest_tick, tick)
	return true

## Records a submitted local input. The sequence is the NetworkSession envelope
## sequence, so authoritative acknowledgements can be matched exactly. Returns
## false when prediction is unavailable or the sequence is already confirmed.
func record_local_input(sequence: int, command: Dictionary) -> bool:
	if not _active or not _local_ready or not _local_alive or command.is_empty():
		return false
	if sequence <= 0 or sequence <= _local_last_ack:
		return false
	for pending_variant: Variant in _pending_inputs:
		var pending: Dictionary = pending_variant
		if int(pending.get("sequence", -1)) == sequence:
			return false
	if _pending_inputs.size() >= MAX_PENDING_INPUTS:
		clear_prediction(FALLBACK_PENDING_OVERFLOW)
		return false
	var command_type := StringName(command.get("type", ""))
	var moves := command_type == &"move"
	var direction := _local_direction
	if moves:
		var requested: Variant = command.get("direction", Vector2.ZERO)
		if requested is Vector2 and (requested as Vector2).is_finite():
			direction = (requested as Vector2).limit_length(1.0)
		_local_direction = direction
	_pending_inputs.append({
		"sequence": sequence,
		"command": command.duplicate(true),
		"direction": direction,
		"moves": moves,
		"recorded_tick": _local_auth_tick,
	})
	# Only movement changes the predicted position. A jump/dash envelope is kept
	# solely so its sequence can be acknowledged and must never replay as a step.
	if moves:
		# Give the local player immediate feedback without breaking the fixed-rate
		# simulation: this step is charged against the next tick accumulator.
		var immediate_step := direction * _movement_speed * FIXED_STEP
		_local_sim_position += immediate_step
		_local_render_position += immediate_step
		_local_step_accumulator -= FIXED_STEP
	return true

## Advances presentation only. Local prediction is a fixed 60 Hz integration and
## remote interpolation samples the buffered server ticks at a render clock.
func tick(delta: float) -> void:
	if not _active:
		return
	_advance_local(maxf(delta, 0.0))
	_advance_remote(maxf(delta, 0.0))

func inject_prediction_error(offset: Vector2) -> bool:
	if not _active or not _local_ready or not _local_alive:
		return false
	if not offset.is_finite():
		return false
	_local_sim_position += offset
	_local_render_position += offset
	_injected_errors += 1
	return true

func get_render_states() -> Dictionary:
	var result: Dictionary = {}
	if not _active:
		return result
	if _local_ready and _local_player_id != &"":
		var local_state: Dictionary = _local_auth_state.duplicate(true)
		local_state["player_id"] = String(_local_player_id)
		local_state["position"] = _local_render_position
		local_state["velocity"] = _local_direction * _movement_speed if _local_alive else Vector2.ZERO
		local_state["dead"] = not _local_alive
		result[String(_local_player_id)] = local_state
	for key: Variant in _remote_render_states:
		var state_variant: Variant = _remote_render_states[key]
		if state_variant is Dictionary:
			result[String(key)] = (state_variant as Dictionary).duplicate(true)
	return result

func get_render_state(player_id: StringName) -> Dictionary:
	var states: Dictionary = get_render_states()
	var key := String(player_id)
	if not states.has(key):
		return {}
	var state: Dictionary = states[key]
	return state

func get_render_position(player_id: StringName) -> Vector2:
	var state := get_render_state(player_id)
	if state.is_empty():
		return Vector2.ZERO
	var position: Variant = state.get("position", Vector2.ZERO)
	return position if position is Vector2 else Vector2.ZERO

func get_pending_input_count() -> int:
	return _pending_inputs.size()

func get_local_prediction() -> Dictionary:
	return {
		"ready": _local_ready,
		"alive": _local_alive,
		"local_player_id": String(_local_player_id),
		"authoritative_tick": _local_auth_tick,
		"authoritative_position": _local_auth_position,
		"simulated_position": _local_sim_position,
		"render_position": _local_render_position,
		"render_error": _local_render_position.distance_to(_local_sim_position),
		"pending_input_count": _pending_inputs.size(),
		"pending_sequences": _pending_sequences(),
		"last_ack_sequence": _local_last_ack,
		"direction": _local_direction,
		"movement_speed": _movement_speed,
		"correction_count": _corrections,
		"large_correction_count": _large_corrections,
		"fallback_count": _fallbacks,
		"injected_error_count": _injected_errors,
		"last_fallback_reason": _last_fallback_reason,
		"last_reconcile": _last_reconcile.duplicate(true),
	}

func get_remote_sample_count(player_id: StringName) -> int:
	var key := String(player_id)
	if not _remote_samples.has(key):
		return 0
	return (_remote_samples[key] as Array).size()

func get_remote_render_state(player_id: StringName) -> Dictionary:
	var key := String(player_id)
	if not _remote_render_states.has(key):
		return {}
	var state: Dictionary = _remote_render_states[key]
	return state.duplicate(true)

func get_remote_render_tick() -> float:
	return _remote_render_tick

## Diagnostic/test seam for deterministic interpolation checks. It only moves
## the presentation clock; authoritative server ticks are never rewritten.
func set_remote_render_tick(tick: float) -> void:
	_remote_render_tick = tick

func get_remote_interpolated_frame_count(player_id: StringName) -> int:
	return int(_remote_interpolated_frames.get(String(player_id), 0))

func get_remote_rejected_count(player_id: StringName) -> int:
	return int(_remote_rejected.get(String(player_id), 0))

func get_remote_snap_event_count(player_id: StringName) -> int:
	return int(_remote_snap_events.get(String(player_id), 0))

func get_remote_fallback_reason(player_id: StringName) -> String:
	return String(_remote_fallback_reasons.get(String(player_id), ""))

func get_remote_snap_total() -> int:
	return _remote_snap_total

## Clears every stale prediction artifact and returns the local presentation to
## the last authoritative checkpoint. Used for death, respawn, teleport, expired
## input, prediction-buffer overflow and epoch changes.
func clear_prediction(reason: String) -> void:
	_pending_inputs.clear()
	_local_direction = Vector2.ZERO
	_local_step_accumulator = 0.0
	if _local_ready:
		_local_sim_position = _local_auth_position
		_local_render_position = _local_auth_position
	_fallbacks += 1
	_last_fallback_reason = reason

func _reset_local_checkpoint() -> void:
	_local_ready = false
	_local_alive = true
	_local_auth_position = Vector2.ZERO
	_local_auth_tick = -1
	_local_auth_state.clear()
	_local_sim_position = Vector2.ZERO
	_local_render_position = Vector2.ZERO
	_local_direction = Vector2.ZERO
	_local_step_accumulator = 0.0
	_local_last_ack = -1
	_pending_inputs.clear()

## An epoch change invalidates every buffered sample and clock. The view keeps
## its configured epoch: the owner must call configure() for the new epoch.
func _reset_epoch_presentation(reason: String) -> void:
	clear_prediction(reason)
	_remote_samples.clear()
	_remote_render_states.clear()
	_remote_interpolated_frames.clear()
	_remote_rejected.clear()
	_remote_snap_events.clear()
	_remote_fallback_reasons.clear()
	_remote_render_tick = 0.0
	_remote_newest_tick = -1
	_remote_has_clock = false

## A complete authoritative snapshot batch is also the roster. Remotes missing
## from it must not keep rendering from samples captured before they left.
func _prune_absent_remotes(seen: Dictionary) -> void:
	for key_variant: Variant in _remote_samples.keys():
		var key := String(key_variant)
		if seen.has(key):
			continue
		_remote_samples.erase(key)
		_remote_render_states.erase(key)

func _install_local_baseline(state: Dictionary, tick: int) -> void:
	var position_variant: Variant = _state_position(state)
	if position_variant == null:
		return
	var position: Vector2 = position_variant
	_local_ready = true
	_local_alive = not bool(state.get("dead", false))
	_local_auth_position = position
	_local_auth_tick = tick
	_local_auth_state = state.duplicate(true)
	_local_auth_state["player_id"] = String(_local_player_id)
	_local_sim_position = position
	_local_render_position = position
	_local_direction = Vector2.ZERO
	_local_step_accumulator = 0.0
	_local_last_ack = int(state.get("ack_sequence", -1))
	_pending_inputs.clear()
	_last_reconcile = {
		"tick": tick,
		"ack_sequence": _local_last_ack,
		"pending_before": 0,
		"pending_after": 0,
		"error": 0.0,
		"fallback": "baseline",
	}

func _reconcile_local(state: Dictionary, tick: int) -> void:
	var position_variant: Variant = _state_position(state)
	if position_variant == null:
		return
	var position: Vector2 = position_variant
	var was_ready := _local_ready
	var was_alive := _local_alive
	var previous_auth := _local_auth_position
	var dead := bool(state.get("dead", false))
	var ack := int(state.get("ack_sequence", -1))
	var pending_before := _pending_inputs.size()
	var teleported: bool = was_ready and _local_auth_tick >= 0 \
		and position.distance_to(previous_auth) > TELEPORT_THRESHOLD

	_local_ready = true
	_local_auth_position = position
	_local_auth_tick = tick
	_local_auth_state = state.duplicate(true)
	_local_auth_state["player_id"] = String(_local_player_id)

	if dead:
		_local_alive = false
		_local_sim_position = position
		_local_render_position = position
		clear_prediction(FALLBACK_DEATH)
		_record_reconcile(tick, ack, pending_before, 0, 0.0, FALLBACK_DEATH)
		return
	if was_ready and not was_alive:
		_local_alive = true
		_local_sim_position = position
		_local_render_position = position
		clear_prediction(FALLBACK_RESPAWN)
		_record_reconcile(tick, ack, pending_before, 0, 0.0, FALLBACK_RESPAWN)
		return
	_local_alive = true

	if ack >= 0:
		_local_last_ack = maxi(_local_last_ack, ack)
		_drop_acknowledged(_local_last_ack)

	if _has_expired_inputs(tick):
		# A sequence that stayed unacknowledged across a whole age window was
		# lost or permanently rejected. Keep presentation authoritative instead
		# of replaying it forever.
		_local_sim_position = position
		_local_render_position = position
		clear_prediction(FALLBACK_INPUT_EXPIRED)
		_record_reconcile(tick, ack, pending_before, 0, 0.0, FALLBACK_INPUT_EXPIRED)
		return

	if teleported:
		_local_sim_position = position
		_local_render_position = position
		clear_prediction(FALLBACK_TELEPORT)
		_record_reconcile(tick, ack, pending_before, _pending_inputs.size(), 0.0, FALLBACK_TELEPORT)
		return

	var simulated := position
	for pending_variant: Variant in _pending_inputs:
		var pending: Dictionary = pending_variant
		if not bool(pending.get("moves", true)):
			continue
		var direction: Variant = pending.get("direction", Vector2.ZERO)
		if direction is Vector2:
			simulated += (direction as Vector2) * _movement_speed * FIXED_STEP
	_local_sim_position = simulated
	var error := _local_render_position.distance_to(simulated)
	if error > LARGE_ERROR_THRESHOLD:
		_local_render_position = simulated
		_large_corrections += 1
		_fallbacks += 1
		_last_fallback_reason = FALLBACK_LARGE_ERROR
		_record_reconcile(tick, ack, pending_before, _pending_inputs.size(), error, FALLBACK_LARGE_ERROR)
	else:
		_corrections += 1
		_record_reconcile(tick, ack, pending_before, _pending_inputs.size(), error, "")

func _record_reconcile(tick: int, ack: int, pending_before: int, pending_after: int, error: float, fallback: String) -> void:
	_last_reconcile = {
		"tick": tick,
		"ack_sequence": ack,
		"pending_before": pending_before,
		"pending_after": pending_after,
		"error": error,
		"fallback": fallback,
	}

func _drop_acknowledged(ack: int) -> void:
	var kept: Array = []
	for pending_variant: Variant in _pending_inputs:
		var pending: Dictionary = pending_variant
		if int(pending.get("sequence", -1)) > ack:
			kept.append(pending)
	_pending_inputs = kept

func _has_expired_inputs(tick: int) -> bool:
	if _pending_inputs.is_empty():
		return false
	var oldest: Dictionary = _pending_inputs[0]
	var recorded_tick := int(oldest.get("recorded_tick", -1))
	if recorded_tick < 0:
		return false
	return tick - recorded_tick > MAX_INPUT_AGE_TICKS

func _pending_sequences() -> Array:
	var result: Array = []
	for pending_variant: Variant in _pending_inputs:
		var pending: Dictionary = pending_variant
		result.append(int(pending.get("sequence", -1)))
	return result

func _advance_local(delta: float) -> void:
	if _local_ready and _local_alive:
		_local_step_accumulator += delta
		var steps := 0
		while _local_step_accumulator + EPSILON >= FIXED_STEP and steps < MAX_LOCAL_STEPS_PER_TICK:
			_local_step_accumulator -= FIXED_STEP
			var predicted_step := _local_direction * _movement_speed * FIXED_STEP
			_local_sim_position += predicted_step
			_local_render_position += predicted_step
			steps += 1
		if steps >= MAX_LOCAL_STEPS_PER_TICK:
			_local_step_accumulator = 0.0
	_smooth_local_render(delta)

func _smooth_local_render(delta: float) -> void:
	var difference := _local_sim_position - _local_render_position
	var distance := difference.length()
	if distance <= SNAP_EPSILON:
		_local_render_position = _local_sim_position
		return
	if delta <= 0.0:
		return
	var factor := 1.0 - exp(-SMOOTH_RATE * delta)
	var step := difference * factor
	var max_step := MAX_CORRECTION_SPEED * delta
	if step.length() > max_step:
		step = step.normalized() * max_step
	_local_render_position += step
	if _local_render_position.distance_to(_local_sim_position) <= SNAP_EPSILON:
		_local_render_position = _local_sim_position

func _push_remote_sample(player_id: StringName, state: Dictionary, tick: int, force: bool) -> bool:
	var key := String(player_id)
	var position_variant: Variant = _state_position(state)
	if position_variant == null:
		return false
	var position: Vector2 = position_variant
	var velocity: Vector2 = Vector2.ZERO
	var velocity_variant: Variant = state.get("velocity", Vector2.ZERO)
	if velocity_variant is Vector2 and (velocity_variant as Vector2).is_finite():
		velocity = velocity_variant
	var samples: Array = _remote_samples.get(key, [])
	var discontinuity := ""
	if not force and not samples.is_empty():
		var last: Dictionary = samples[samples.size() - 1]
		var last_tick := int(last.get("tick", -1))
		if tick <= last_tick:
			_remote_rejected[key] = int(_remote_rejected.get(key, 0)) + 1
			return false
		var last_position: Variant = last.get("position", Vector2.ZERO)
		if last_position is Vector2 and position.distance_to(last_position) > TELEPORT_THRESHOLD:
			discontinuity = FALLBACK_REMOTE_TELEPORT
		elif bool(last.get("dead", false)) != bool(state.get("dead", false)):
			discontinuity = FALLBACK_REMOTE_LIFE_STATE
		elif state.has("revision") and int(state.get("revision", -1)) < int(last.get("revision", -1)):
			discontinuity = FALLBACK_REMOTE_REVISION
		if discontinuity != "":
			samples.clear()
			_remote_snap_events[key] = int(_remote_snap_events.get(key, 0)) + 1
			_remote_snap_total += 1
			_remote_fallback_reasons[key] = discontinuity
	var sample: Dictionary = state.duplicate(true)
	sample["player_id"] = String(player_id)
	sample["position"] = position
	sample["velocity"] = velocity
	sample["tick"] = tick
	sample["dead"] = bool(state.get("dead", false))
	samples.append(sample)
	if samples.size() > MAX_REMOTE_SAMPLES:
		samples.pop_front()
	_remote_samples[key] = samples
	_remote_newest_tick = maxi(_remote_newest_tick, tick)
	if samples.size() == 1 or discontinuity != "":
		var immediate: Dictionary = sample.duplicate(true)
		immediate["interpolated"] = false
		immediate["sample_count"] = samples.size()
		_remote_render_states[key] = immediate
	return true

func _advance_remote(delta: float) -> void:
	if not _remote_has_clock:
		return
	_remote_render_tick += RENDER_TICK_RATE * delta
	if _remote_newest_tick >= 0 and float(_remote_newest_tick) - _remote_render_tick > MAX_REMOTE_LAG_TICKS:
		_remote_render_tick = float(_remote_newest_tick) - REMOTE_DELAY_TICKS
		_last_fallback_reason = FALLBACK_REMOTE_LAG
		for key_variant: Variant in _remote_samples.keys():
			_remote_fallback_reasons[String(key_variant)] = FALLBACK_REMOTE_LAG
	for key_variant: Variant in _remote_samples.keys():
		var key := String(key_variant)
		var sampled: Dictionary = _sample_remote(key, _remote_render_tick)
		if sampled.is_empty():
			continue
		_remote_render_states[key] = sampled
		if bool(sampled.get("interpolated", false)):
			_remote_interpolated_frames[key] = int(_remote_interpolated_frames.get(key, 0)) + 1

func _sample_remote(key: String, render_tick: float) -> Dictionary:
	var samples: Array = _remote_samples.get(key, [])
	if samples.is_empty():
		return {}
	var first: Dictionary = samples[0]
	var last: Dictionary = samples[samples.size() - 1]
	if samples.size() == 1 or render_tick <= float(first.get("tick", 0)):
		var only: Dictionary = first.duplicate(true)
		only["interpolated"] = false
		only["sample_count"] = samples.size()
		return only
	if render_tick >= float(last.get("tick", 0)):
		var newest: Dictionary = last.duplicate(true)
		newest["interpolated"] = false
		newest["sample_count"] = samples.size()
		return newest
	for index in range(samples.size() - 1):
		var a: Dictionary = samples[index]
		var b: Dictionary = samples[index + 1]
		var a_tick := int(a.get("tick", 0))
		var b_tick := int(b.get("tick", 0))
		if render_tick < float(a_tick) or render_tick > float(b_tick):
			continue
		var span := float(b_tick - a_tick)
		var weight := 0.0 if span <= 0.0 else (render_tick - float(a_tick)) / span
		weight = clampf(weight, 0.0, 1.0)
		var a_position: Variant = a.get("position", Vector2.ZERO)
		var b_position: Variant = b.get("position", Vector2.ZERO)
		var a_velocity: Variant = a.get("velocity", Vector2.ZERO)
		var b_velocity: Variant = b.get("velocity", Vector2.ZERO)
		var sampled: Dictionary = b.duplicate(true)
		sampled["position"] = (a_position as Vector2).lerp(b_position as Vector2, weight)
		sampled["velocity"] = (a_velocity as Vector2).lerp(b_velocity as Vector2, weight)
		sampled["dead"] = bool(a.get("dead", false))
		sampled["interpolated"] = weight > 0.0 and weight < 1.0
		sampled["sample_count"] = samples.size()
		return sampled
	var fallback: Dictionary = last.duplicate(true)
	fallback["interpolated"] = false
	fallback["sample_count"] = samples.size()
	return fallback

func _state_position(state: Dictionary) -> Variant:
	var position: Variant = state.get("position", null)
	if not (position is Vector2):
		return null
	if not (position as Vector2).is_finite():
		return null
	return position
