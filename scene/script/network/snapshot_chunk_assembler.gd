class_name SnapshotChunkAssembler
extends RefCounted

## Reassembles one complete movement tick from MTU-safe packets. A newer tick
## always supersedes an incomplete older tick, so packets from different ticks
## can never be combined into a false world state.

const RESULT_COMPLETE: String = "complete"
const RESULT_PENDING: String = "fragment_pending"
const REJECT_INVALID_FRAGMENT: String = "invalid_fragment"
const REJECT_STALE_FRAGMENT: String = "stale_fragment"

var _pending_tick: int = -1
var _pending_epoch: int = -1
var _chunk_count: int = 0
var _player_count: int = 0
var _chunks: Dictionary = {}

func reset() -> void:
	_pending_tick = -1
	_pending_epoch = -1
	_chunk_count = 0
	_player_count = 0
	_chunks.clear()

## Legacy single-packet batches pass through unchanged. Fragmented batches
## return {complete, reason, batch}; pending fragments never expose players.
func push(packet: Dictionary) -> Dictionary:
	var tick := int(packet.get("server_tick", -1))
	var epoch := int(packet.get("match_epoch", -1))
	if not packet.has("snapshot_chunk_count"):
		return {"complete": true, "reason": RESULT_COMPLETE,
			"tick": tick, "batch": packet.duplicate(true)}
	var count := int(packet.get("snapshot_chunk_count", 0))
	var index := int(packet.get("snapshot_chunk_index", -1))
	var expected_players := int(packet.get("snapshot_player_count", -1))
	var players_variant: Variant = packet.get("players", null)
	if tick < 0 or epoch <= 0 or count <= 0 or index < 0 or index >= count \
			or expected_players < 0 or not players_variant is Dictionary:
		return _result(false, REJECT_INVALID_FRAGMENT, tick)
	if _pending_tick >= 0 and tick < _pending_tick:
		return _result(false, REJECT_STALE_FRAGMENT, tick)
	if tick > _pending_tick:
		_start_tick(tick, epoch, count, expected_players)
	elif tick == _pending_tick and (epoch != _pending_epoch or count != _chunk_count \
			or expected_players != _player_count):
		reset()
		return _result(false, REJECT_INVALID_FRAGMENT, tick)
	elif _pending_tick < 0:
		_start_tick(tick, epoch, count, expected_players)
	if _chunks.has(index):
		return _result(false, RESULT_PENDING, tick)
	_chunks[index] = (players_variant as Dictionary).duplicate(true)
	if _chunks.size() < _chunk_count:
		return _result(false, RESULT_PENDING, tick)
	var players: Dictionary = {}
	for chunk_index in range(_chunk_count):
		if not _chunks.has(chunk_index):
			return _result(false, RESULT_PENDING, tick)
		var chunk: Dictionary = _chunks[chunk_index]
		for player_id: Variant in chunk:
			if players.has(player_id):
				reset()
				return _result(false, REJECT_INVALID_FRAGMENT, tick)
			players[player_id] = chunk[player_id]
	if players.size() != _player_count:
		reset()
		return _result(false, REJECT_INVALID_FRAGMENT, tick)
	var batch := packet.duplicate(true)
	batch["players"] = players
	batch.erase("snapshot_chunk_index")
	batch.erase("snapshot_chunk_count")
	batch.erase("snapshot_player_count")
	reset()
	return {"complete": true, "reason": RESULT_COMPLETE, "tick": tick,
		"batch": batch}

func get_pending_tick() -> int:
	return _pending_tick

func get_pending_chunk_count() -> int:
	return _chunks.size()

func _start_tick(tick: int, epoch: int, count: int, player_count: int) -> void:
	_pending_tick = tick
	_pending_epoch = epoch
	_chunk_count = count
	_player_count = player_count
	_chunks.clear()

func _result(complete: bool, reason: String, tick: int) -> Dictionary:
	return {"complete": complete, "reason": reason, "tick": tick, "batch": {}}
