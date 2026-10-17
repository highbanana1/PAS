class_name SnapshotReplica
extends RefCounted

## Client-side authoritative snapshot replica. It accepts only batches from the
## configured match epoch whose server tick advances strictly forward, then
## exposes the latest per-player state. It never predicts, interpolates or
## decides gameplay.

const REJECT_NOT_CONFIGURED: String = "not_configured"
const REJECT_STALE_EPOCH: String = "stale_epoch"
const REJECT_REGRESSED_TICK: String = "regressed_tick"
const REJECT_INVALID_BATCH: String = "invalid_batch"

var _match_epoch: int = 0
var _last_tick: int = -1
var _states: Dictionary = {}
var _applied_batches: int = 0
var _last_player_count: int = 0
var _rejections: Dictionary = {
	REJECT_NOT_CONFIGURED: 0,
	REJECT_STALE_EPOCH: 0,
	REJECT_REGRESSED_TICK: 0,
	REJECT_INVALID_BATCH: 0,
}

func configure(match_epoch: int) -> void:
	_match_epoch = match_epoch
	_last_tick = -1
	_states.clear()
	_applied_batches = 0
	_last_player_count = 0
	for reason: String in _rejections.keys():
		_rejections[reason] = 0

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

## Returns {applied, reason, tick, player_count}. A rejected batch leaves the
## replica state and last applied tick untouched.
func apply_batch(batch: Dictionary) -> Dictionary:
	if _match_epoch <= 0:
		return _reject(REJECT_NOT_CONFIGURED, -1)
	var epoch := int(batch.get("match_epoch", -1))
	if epoch != _match_epoch:
		return _reject(REJECT_STALE_EPOCH, int(batch.get("server_tick", -1)))
	var tick := int(batch.get("server_tick", -1))
	if tick <= 0:
		return _reject(REJECT_INVALID_BATCH, tick)
	if tick <= _last_tick:
		return _reject(REJECT_REGRESSED_TICK, tick)
	var players_variant: Variant = batch.get("players", null)
	if not (players_variant is Dictionary):
		return _reject(REJECT_INVALID_BATCH, tick)
	var players: Dictionary = players_variant
	var next_states: Dictionary = {}
	for raw_id: Variant in players:
		var state_variant: Variant = players[raw_id]
		if not (state_variant is Dictionary):
			return _reject(REJECT_INVALID_BATCH, tick)
		var state: Dictionary = state_variant
		var player_id := String(state.get("player_id", raw_id))
		if player_id.is_empty():
			return _reject(REJECT_INVALID_BATCH, tick)
		var position: Variant = state.get("position", null)
		var velocity: Variant = state.get("velocity", null)
		if not (position is Vector2) or not (position as Vector2).is_finite():
			return _reject(REJECT_INVALID_BATCH, tick)
		if not (velocity is Vector2) or not (velocity as Vector2).is_finite():
			return _reject(REJECT_INVALID_BATCH, tick)
		var revision := int(state.get("revision", -1))
		if revision < 0:
			return _reject(REJECT_INVALID_BATCH, tick)
		var copy: Dictionary = state.duplicate(true)
		copy["player_id"] = player_id
		copy["revision"] = revision
		next_states[player_id] = copy
	_states = next_states
	_last_tick = tick
	_last_player_count = next_states.size()
	_applied_batches += 1
	return {
		"applied": true,
		"reason": "",
		"tick": tick,
		"player_count": _last_player_count,
	}

func _reject(reason: String, tick: int) -> Dictionary:
	_rejections[reason] = int(_rejections.get(reason, 0)) + 1
	return {
		"applied": false,
		"reason": reason,
		"tick": tick,
		"player_count": 0,
	}
