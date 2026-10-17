class_name NetworkSession
extends Node

## Deep ENet session seam for one host-authoritative match. It owns the
## transport peer, seat allocation, the stable peer-to-player mapping, the
## match epoch, and command-envelope validation. It never decides gameplay.
##
## Identity is always taken from the RPC remote sender. Any player_id carried
## in an envelope or command payload is recorded for diagnostics only.

signal identity_assigned(identity: Dictionary)
signal identity_updated(identity: Dictionary)
signal player_joined(peer_id: int, player_id: String)
signal player_left(peer_id: int, player_id: String)
signal command_result(result: Dictionary)
signal session_closed()
signal join_failed(reason: String)

const MAX_SEATS: int = 16
const MAX_REMOTE_CLIENTS: int = MAX_SEATS - 1
const INITIAL_LIFE_ID: int = 1
const SERVER_PEER_ID: int = 1
const DEFAULT_PORT: int = 0
const COMMAND_CHANNEL: int = 1

const REJECT_UNKNOWN_PEER: String = "unknown_peer"
const REJECT_INVALID_ENVELOPE: String = "invalid_envelope"
const REJECT_STALE_EPOCH: String = "stale_epoch"
const REJECT_STALE_LIFE: String = "stale_life"
const REJECT_DUPLICATE_SEQUENCE: String = "duplicate_sequence"
const REJECT_REGRESSED_SEQUENCE: String = "regressed_sequence"

var _is_host: bool = false
var _is_active: bool = false
var _match_epoch: int = 0
var _max_seats: int = MAX_SEATS
var _local_port: int = 0
var _next_seat: int = 0
var _local_sequence: int = 0
var _local_identity: Dictionary = {}
var _peer_identities: Dictionary = {}
var _player_peers: Dictionary = {}
var _last_sequences: Dictionary = {}
var _commands: Array[Dictionary] = []
var _rejections: Array[Dictionary] = []
var _command_results: Array[Dictionary] = []

func host(port: int = DEFAULT_PORT, options: Dictionary = {}) -> int:
	if not is_inside_tree():
		return ERR_UNCONFIGURED
	if _is_active:
		return ERR_ALREADY_IN_USE
	var seats: int = int(options.get("seats", MAX_SEATS))
	if seats < 1 or seats > MAX_SEATS:
		return ERR_INVALID_PARAMETER
	var epoch: int = int(options.get("match_epoch", 0))
	if epoch <= 0:
		epoch = int(Time.get_ticks_usec())
	var remote_capacity: int = maxi(seats - 1, 1)
	var peer := ENetMultiplayerPeer.new()
	var error: int = peer.create_server(port, remote_capacity, 2)
	if error != OK:
		return error
	_reset_state()
	_is_host = true
	_match_epoch = epoch
	_max_seats = seats
	_local_port = port
	_connect_transport_signals()
	multiplayer.multiplayer_peer = peer
	_is_active = true
	_next_seat = 1
	var host_identity := _make_identity(SERVER_PEER_ID, _next_seat, INITIAL_LIFE_ID)
	_peer_identities[SERVER_PEER_ID] = host_identity
	_player_peers[StringName(host_identity["player_id"])] = SERVER_PEER_ID
	_last_sequences[StringName(host_identity["player_id"])] = 0
	_local_identity = host_identity.duplicate(true)
	return OK

func join(address: String, port: int) -> int:
	if not is_inside_tree():
		return ERR_UNCONFIGURED
	if _is_active:
		return ERR_ALREADY_IN_USE
	if address.is_empty() or port <= 0 or port > 65535:
		return ERR_INVALID_PARAMETER
	var peer := ENetMultiplayerPeer.new()
	var error: int = peer.create_client(address, port, 2)
	if error != OK:
		return error
	_reset_state()
	_is_host = false
	_max_seats = MAX_SEATS
	_local_port = port
	_connect_transport_signals()
	multiplayer.multiplayer_peer = peer
	_is_active = true
	return OK

func stop() -> void:
	var was_active := _is_active
	_is_active = false
	_is_host = false
	if is_inside_tree():
		var api: MultiplayerAPI = multiplayer
		var peer: MultiplayerPeer = api.multiplayer_peer
		if peer != null:
			peer.close()
			api.multiplayer_peer = null
	_reset_state()
	if was_active:
		session_closed.emit()

func is_host() -> bool:
	return _is_host

func is_active() -> bool:
	if not _is_active or not is_inside_tree():
		return false
	return multiplayer.multiplayer_peer != null

func get_port() -> int:
	if _is_host and is_inside_tree():
		var api: MultiplayerAPI = multiplayer
		var peer: MultiplayerPeer = api.multiplayer_peer
		if peer is ENetMultiplayerPeer:
			var enet: ENetMultiplayerPeer = peer
			var enet_host: ENetConnection = enet.get_host()
			if enet_host != null:
				return enet_host.get_local_port()
	return _local_port

func get_match_epoch() -> int:
	return _match_epoch

func get_max_seats() -> int:
	return _max_seats

func get_remote_capacity() -> int:
	return maxi(_max_seats - 1, 0)

func get_player_count() -> int:
	return _peer_identities.size()

func get_local_identity() -> Dictionary:
	if _local_identity.is_empty():
		return {}
	return _local_identity.duplicate(true)

func get_identity_for_peer(peer_id: int) -> Dictionary:
	if not _peer_identities.has(peer_id):
		return {}
	var identity: Dictionary = _peer_identities[peer_id]
	return identity.duplicate(true)

func get_player_id_for_peer(peer_id: int) -> StringName:
	if not _peer_identities.has(peer_id):
		return &""
	var identity: Dictionary = _peer_identities[peer_id]
	return StringName(String(identity.get("player_id", "")))

func get_peer_id_for_player(player_id: StringName) -> int:
	if not _player_peers.has(player_id):
		return 0
	return int(_player_peers[player_id])

func set_player_life(player_id: StringName, life_id: int) -> bool:
	if not _is_host or not _is_active:
		return false
	if not _player_peers.has(player_id) or life_id < INITIAL_LIFE_ID:
		return false
	var peer_id: int = int(_player_peers[player_id])
	var identity: Dictionary = _peer_identities[peer_id]
	if life_id <= int(identity.get("life_id", 0)):
		return false
	identity["life_id"] = life_id
	_last_sequences[player_id] = 0
	if peer_id == SERVER_PEER_ID:
		_local_identity = identity.duplicate(true)
		identity_updated.emit(get_local_identity())
	else:
		_rpc_assign_life.rpc_id(peer_id, life_id)
	return true

## Builds and sends an envelope. Negative sequence/life_id/epoch use the local
## identity; explicit values allow retransmission/staleness tests. Identity is
## never accepted from these values: the host always resolves the sender.
func send_command(command: Dictionary, sequence: int = -1, life_id: int = -1, epoch: int = -1) -> int:
	if not is_active() or _local_identity.is_empty() or command.is_empty():
		return -1
	var use_sequence := sequence
	if use_sequence < 0:
		_local_sequence += 1
		use_sequence = _local_sequence
	elif use_sequence > _local_sequence:
		_local_sequence = use_sequence
	var use_life: int = life_id
	if use_life < 0:
		use_life = int(_local_identity.get("life_id", INITIAL_LIFE_ID))
	var use_epoch: int = epoch
	if use_epoch < 0:
		use_epoch = _match_epoch
	var envelope := {
		"sequence": use_sequence,
		"life_id": use_life,
		"epoch": use_epoch,
		"player_id": String(_local_identity.get("player_id", "")),
		"command": command.duplicate(true),
	}
	if _is_host:
		_process_envelope(SERVER_PEER_ID, envelope)
	else:
		_rpc_submit_envelope.rpc_id(SERVER_PEER_ID, envelope)
	return use_sequence

func drain_commands() -> Array[Dictionary]:
	var result: Array[Dictionary] = []
	result.append_array(_commands)
	_commands.clear()
	return result

func drain_rejections() -> Array[Dictionary]:
	var result: Array[Dictionary] = []
	result.append_array(_rejections)
	_rejections.clear()
	return result

func drain_command_results() -> Array[Dictionary]:
	var result: Array[Dictionary] = []
	result.append_array(_command_results)
	_command_results.clear()
	return result

@rpc("any_peer", "call_remote", "unreliable_ordered", COMMAND_CHANNEL)
func _rpc_submit_envelope(envelope: Dictionary) -> void:
	if not _is_host or not _is_active:
		return
	var sender: int = int(multiplayer.get_remote_sender_id())
	if sender <= 0 or sender == SERVER_PEER_ID:
		return
	_process_envelope(sender, envelope)

@rpc("authority", "call_remote", "reliable")
func _rpc_assign_identity(identity: Dictionary) -> void:
	if _is_host or not _is_active:
		return
	if int(multiplayer.get_remote_sender_id()) != SERVER_PEER_ID:
		return
	var player_id := String(identity.get("player_id", ""))
	var peer_id: int = int(identity.get("peer_id", 0))
	var epoch: int = int(identity.get("match_epoch", 0))
	var life_id: int = int(identity.get("life_id", 0))
	if player_id.is_empty() or peer_id <= 0 or epoch <= 0 or life_id < INITIAL_LIFE_ID:
		return
	_local_identity = identity.duplicate(true)
	_match_epoch = epoch
	_local_sequence = 0
	identity_assigned.emit(get_local_identity())

@rpc("authority", "call_remote", "reliable")
func _rpc_assign_life(life_id: int) -> void:
	if _is_host or not _is_active or _local_identity.is_empty():
		return
	if int(multiplayer.get_remote_sender_id()) != SERVER_PEER_ID:
		return
	if life_id < INITIAL_LIFE_ID:
		return
	_local_identity["life_id"] = life_id
	identity_updated.emit(get_local_identity())

@rpc("authority", "call_remote", "reliable")
func _rpc_command_result(result: Dictionary) -> void:
	if _is_host or not _is_active:
		return
	if int(multiplayer.get_remote_sender_id()) != SERVER_PEER_ID:
		return
	_command_results.append(result.duplicate(true))
	command_result.emit(result.duplicate(true))

func _process_envelope(sender: int, envelope: Dictionary) -> void:
	var identity: Dictionary = {}
	if _peer_identities.has(sender):
		identity = _peer_identities[sender]
	var player_id := String(identity.get("player_id", ""))
	var sequence: int = int(envelope.get("sequence", -1))
	var life_id: int = int(envelope.get("life_id", -1))
	var epoch: int = int(envelope.get("epoch", -1))
	var command_variant: Variant = envelope.get("command", {})
	var command: Dictionary = {}
	if command_variant is Dictionary:
		command = command_variant
	var claimed_player_id := String(envelope.get("player_id", ""))
	if command.has("player_id"):
		claimed_player_id = String(command.get("player_id", ""))
	var base := {
		"accepted": false,
		"reason": "",
		"player_id": player_id,
		"peer_id": sender,
		"sequence": sequence,
		"life_id": life_id,
		"epoch": epoch,
		"claimed_player_id": claimed_player_id,
	}
	if identity.is_empty():
		_reject(sender, base, REJECT_UNKNOWN_PEER)
		return
	if command.is_empty():
		_reject(sender, base, REJECT_INVALID_ENVELOPE)
		return
	if epoch != _match_epoch:
		_reject(sender, base, REJECT_STALE_EPOCH)
		return
	if life_id != int(identity.get("life_id", 0)):
		_reject(sender, base, REJECT_STALE_LIFE)
		return
	if sequence <= 0:
		_reject(sender, base, REJECT_INVALID_ENVELOPE)
		return
	var last_sequence: int = int(_last_sequences.get(StringName(player_id), 0))
	if sequence == last_sequence:
		_reject(sender, base, REJECT_DUPLICATE_SEQUENCE)
		return
	if sequence < last_sequence:
		_reject(sender, base, REJECT_REGRESSED_SEQUENCE)
		return
	_last_sequences[StringName(player_id)] = sequence
	var sanitized: Dictionary = command.duplicate(true)
	sanitized.erase("player_id")
	sanitized.erase("peer_id")
	var accepted := base.duplicate(true)
	accepted["accepted"] = true
	accepted["command"] = sanitized
	_commands.append(accepted)
	_command_results.append(accepted.duplicate(true))
	command_result.emit(accepted.duplicate(true))
	if sender != SERVER_PEER_ID:
		_rpc_command_result.rpc_id(sender, accepted)

func _reject(sender: int, base: Dictionary, reason: String) -> void:
	var rejected := base.duplicate(true)
	rejected["accepted"] = false
	rejected["reason"] = reason
	_rejections.append(rejected)
	_command_results.append(rejected.duplicate(true))
	command_result.emit(rejected.duplicate(true))
	if sender != SERVER_PEER_ID:
		_rpc_command_result.rpc_id(sender, rejected)

func _make_identity(peer_id: int, seat: int, life_id: int) -> Dictionary:
	return {
		"player_id": "player_%d" % seat,
		"peer_id": peer_id,
		"seat": seat,
		"match_epoch": _match_epoch,
		"life_id": life_id,
	}

func _connect_transport_signals() -> void:
	var api: MultiplayerAPI = multiplayer
	if not api.peer_connected.is_connected(_on_peer_connected):
		api.peer_connected.connect(_on_peer_connected)
	if not api.peer_disconnected.is_connected(_on_peer_disconnected):
		api.peer_disconnected.connect(_on_peer_disconnected)
	if not api.connected_to_server.is_connected(_on_connected_to_server):
		api.connected_to_server.connect(_on_connected_to_server)
	if not api.connection_failed.is_connected(_on_connection_failed):
		api.connection_failed.connect(_on_connection_failed)
	if not api.server_disconnected.is_connected(_on_server_disconnected):
		api.server_disconnected.connect(_on_server_disconnected)

func _on_peer_connected(peer_id: int) -> void:
	if not _is_host or not _is_active or peer_id == SERVER_PEER_ID:
		return
	if _peer_identities.has(peer_id):
		return
	if _peer_identities.size() >= _max_seats:
		return
	_next_seat += 1
	var identity := _make_identity(peer_id, _next_seat, INITIAL_LIFE_ID)
	_peer_identities[peer_id] = identity
	_player_peers[StringName(identity["player_id"])] = peer_id
	_last_sequences[StringName(identity["player_id"])] = 0
	_rpc_assign_identity.rpc_id(peer_id, identity)
	player_joined.emit(peer_id, String(identity["player_id"]))

func _on_peer_disconnected(peer_id: int) -> void:
	if not _is_host:
		return
	if not _peer_identities.has(peer_id):
		return
	var identity: Dictionary = _peer_identities[peer_id]
	var player_id := String(identity.get("player_id", ""))
	_peer_identities.erase(peer_id)
	_player_peers.erase(StringName(player_id))
	_last_sequences.erase(StringName(player_id))
	player_left.emit(peer_id, player_id)

func _on_connected_to_server() -> void:
	pass

func _on_connection_failed() -> void:
	if _is_host:
		return
	_is_active = false
	join_failed.emit("connection_failed")

func _on_server_disconnected() -> void:
	if _is_host:
		return
	_is_active = false
	session_closed.emit()

func _reset_state() -> void:
	_match_epoch = 0
	_max_seats = MAX_SEATS
	_local_port = 0
	_next_seat = 0
	_local_sequence = 0
	_local_identity = {}
	_peer_identities.clear()
	_player_peers.clear()
	_last_sequences.clear()
	_commands.clear()
	_rejections.clear()
	_command_results.clear()

func _exit_tree() -> void:
	if _is_active:
		stop()
