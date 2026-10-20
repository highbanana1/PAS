class_name SnapshotReplica
extends RefCounted

## Client-side authoritative snapshot replica. A reliable baseline installs the
## first complete authoritative state; unreliable snapshot batches are ignored
## until that baseline has been applied and thereafter only advance strictly
## forward. Duplicate/older baselines and regressed batches are idempotently
## rejected. It never predicts, interpolates or decides gameplay.

const REJECT_NOT_CONFIGURED: String = "not_configured"
const REJECT_STALE_EPOCH: String = "stale_epoch"
const REJECT_REGRESSED_TICK: String = "regressed_tick"
const REJECT_INVALID_BATCH: String = "invalid_batch"
const REJECT_BASELINE_REQUIRED: String = "baseline_required"
const REJECT_DUPLICATE_BASELINE: String = "duplicate_baseline"
const REJECT_STALE_BASELINE: String = "stale_baseline"
const REJECT_NOT_ACTIVE: String = "not_active"

var _match_epoch: int = 0
var _last_tick: int = -1
var _states: Dictionary = {}
var _applied_batches: int = 0
var _last_player_count: int = 0
var _active: bool = false
var _baseline_applied: bool = false
var _baseline_applied_count: int = 0
var _rejections: Dictionary = {
	REJECT_NOT_CONFIGURED: 0,
	REJECT_STALE_EPOCH: 0,
	REJECT_REGRESSED_TICK: 0,
	REJECT_INVALID_BATCH: 0,
	REJECT_BASELINE_REQUIRED: 0,
	REJECT_DUPLICATE_BASELINE: 0,
	REJECT_STALE_BASELINE: 0,
	REJECT_NOT_ACTIVE: 0,
}

func configure(match_epoch: int) -> void:
	_match_epoch = match_epoch
	_last_tick = -1
	_states.clear()
	_applied_batches = 0
	_last_player_count = 0
	_active = true
	_baseline_applied = false
	_baseline_applied_count = 0
	for reason: String in _rejections.keys():
		_rejections[reason] = 0

func deactivate() -> void:
	_active = false

func get_active() -> bool:
	return _active

func has_baseline() -> bool:
	return _baseline_applied

func get_baseline_applied_count() -> int:
	return _baseline_applied_count

func get_match_epoch() -> int:
	return _match_epoch

func get_last_tick() -> int:
	return _last_tick

func get_applied_batch_count() -> int:
	return _applied_batches

func get_last_player_count() -> int:
	return _last_player_count

func get_state(player_id: StringName) -> Dictionary:
	var key := String(player_id)
	if not _states.has(key):
		return {}
	return (_states[key] as Dictionary).duplicate(true)

func get_states() -> Dictionary:
	return _states.duplicate(true)

func get_rejected_count(reason: String) -> int:
	return int(_rejections.get(reason, 0))

## Installs the reliable full baseline. A baseline older than or equal to the
## applied baseline/snapshot tick is rejected without touching replica state.
## Returns {applied, reason, tick, player_count, baseline}.
func apply_baseline(baseline: Dictionary) -> Dictionary:
	var tick := int(baseline.get("baseline_tick", baseline.get("server_tick", -1)))
	if not _active:
		return _reject(REJECT_NOT_ACTIVE, tick)
	if _match_epoch <= 0:
		return _reject(REJECT_NOT_CONFIGURED, tick)
	if int(baseline.get("match_epoch", -1)) != _match_epoch:
		return _reject(REJECT_STALE_EPOCH, tick)
	if tick < 0:
		return _reject(REJECT_INVALID_BATCH, tick)
	if _baseline_applied:
		if tick < _last_tick:
			return _reject(REJECT_STALE_BASELINE, tick)
		return _reject(REJECT_DUPLICATE_BASELINE, tick)
	var players_variant: Variant = baseline.get("players", null)
	if not (players_variant is Dictionary):
		return _reject(REJECT_INVALID_BATCH, tick)
	var states_variant: Variant = _extract_states(players_variant, tick)
	if states_variant == null:
		return _reject(REJECT_INVALID_BATCH, tick)
	_states = states_variant
	_last_tick = tick
	_last_player_count = _states.size()
	_baseline_applied = true
	_baseline_applied_count += 1
	return {
		"applied": true,
		"reason": "",
		"tick": tick,
		"player_count": _last_player_count,
		"baseline": true,
	}

## Returns {applied, reason, tick, player_count}. A rejected batch leaves the
## replica state and last applied tick untouched.
func apply_batch(batch: Dictionary) -> Dictionary:
	var tick := int(batch.get("server_tick", -1))
	if not _active:
		return _reject(REJECT_NOT_ACTIVE, tick)
	if _match_epoch <= 0:
		return _reject(REJECT_NOT_CONFIGURED, tick)
	var epoch := int(batch.get("match_epoch", -1))
	if epoch != _match_epoch:
		return _reject(REJECT_STALE_EPOCH, tick)
	if not _baseline_applied:
		return _reject(REJECT_BASELINE_REQUIRED, tick)
	if tick <= 0:
		return _reject(REJECT_INVALID_BATCH, tick)
	if tick <= _last_tick:
		return _reject(REJECT_REGRESSED_TICK, tick)
	var players_variant: Variant = batch.get("players", null)
	if not (players_variant is Dictionary):
		return _reject(REJECT_INVALID_BATCH, tick)
	var states_variant: Variant = _extract_states(players_variant, tick)
	if states_variant == null:
		return _reject(REJECT_INVALID_BATCH, tick)
	_states = states_variant
	_last_tick = tick
	_last_player_count = _states.size()
	_applied_batches += 1
	return {
		"applied": true,
		"reason": "",
		"tick": tick,
		"player_count": _last_player_count,
	}

func _extract_states(players: Dictionary, tick: int) -> Variant:
	var next_states: Dictionary = {}
	for raw_id: Variant in players:
		var state_variant: Variant = players[raw_id]
		if not (state_variant is Dictionary):
			return null
		var state: Dictionary = state_variant
		var player_id := String(state.get("player_id", raw_id))
		if player_id.is_empty():
			return null
		var position: Variant = state.get("position", null)
		var velocity: Variant = state.get("velocity", null)
		if not (position is Vector2) or not (position as Vector2).is_finite():
			return null
		if not (velocity is Vector2) or not (velocity as Vector2).is_finite():
			return null
		if not state.has("revision"):
			return null
		var revision := int(state.get("revision", -1))
		if revision < 0:
			return null
		var copy: Dictionary = state.duplicate(true)
		copy["player_id"] = player_id
		copy["revision"] = revision
		if not copy.has("tick"):
			copy["tick"] = tick
		next_states[player_id] = copy
	return next_states

func _reject(reason: String, tick: int) -> Dictionary:
	_rejections[reason] = int(_rejections.get(reason, 0)) + 1
	return {
		"applied": false,
		"reason": reason,
		"tick": tick,
		"player_count": 0,
	}
