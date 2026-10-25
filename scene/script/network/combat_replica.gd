extends RefCounted
## Full checkpoints with a tick/revision watermark; old packets cannot resurrect pellets.
var _epoch: int = 0
var _tick: int = -1
var _revision: int = -1
var _state: Dictionary = {}
var _players: Dictionary = {}

func configure(epoch: int) -> void:
	_epoch = epoch
	_tick = -1
	_revision = -1
	_state = {}
	_players = {}

func apply_packet(packet: Dictionary) -> bool:
	if int(packet.get("match_epoch", -1)) != _epoch or not packet.get("combat") is Dictionary:
		return false
	var tick := int(packet.get("server_tick", -1))
	var state: Dictionary = packet.combat
	var revision := int(state.get("revision", -1))
	if tick < _tick or revision < _revision or (tick == _tick and revision <= _revision):
		return false
	if not state.get("projectiles") is Array or not state.get("events") is Array:
		return false
	_tick = tick
	_revision = revision
	_state = state.duplicate(true)
	_players = packet.get("players", {}).duplicate(true)
	return true

func get_state() -> Dictionary:
	return _state.duplicate(true)

func get_player(player_id: String) -> Dictionary:
	return _players.get(player_id, {}).duplicate(true)

func clear() -> void:
	_state = {}
	_players = {}
