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
signal player_resumed(peer_id: int, player_id: String)
signal player_reservation_expired(player_id: String)
signal command_result(result: Dictionary)
signal snapshot_batch_received(batch: Dictionary)
signal combat_state_received(packet: Dictionary)
signal baseline_received(baseline: Dictionary)
signal baseline_applied(baseline: Dictionary)
signal baseline_rejected(result: Dictionary)
signal session_closed()
signal join_failed(reason: String)

const MAX_SEATS: int = 16
const MAX_REMOTE_CLIENTS: int = MAX_SEATS - 1
const JOIN_REJECTION_SLOTS: int = 1
const INITIAL_LIFE_ID: int = 1
const SERVER_PEER_ID: int = 1
const DEFAULT_PORT: int = 0
const BASELINE_CHANNEL: int = 0
const COMMAND_CHANNEL: int = 1
const SNAPSHOT_CHANNEL: int = 2
const MAX_CHANNELS: int = 3
const RECONNECT_WINDOW_MSEC: int = 30000
const JOIN_HANDSHAKE_MSEC: int = 5000

const REJECT_UNKNOWN_PEER: String = "unknown_peer"
const REJECT_INVALID_ENVELOPE: String = "invalid_envelope"
const REJECT_STALE_EPOCH: String = "stale_epoch"
const REJECT_STALE_LIFE: String = "stale_life"
const REJECT_DUPLICATE_SEQUENCE: String = "duplicate_sequence"
const REJECT_REGRESSED_SEQUENCE: String = "regressed_sequence"
const REJECT_INVALID_BASELINE: String = "invalid_baseline"
const REJECT_DUPLICATE_BASELINE: String = "duplicate_baseline"
const REJECT_STALE_BASELINE: String = "stale_baseline"

var _is_host: bool = false
var _is_active: bool = false
var _match_epoch: int = 0
var _max_seats: int = MAX_SEATS
var _local_port: int = 0
var _next_player_serial: int = 0
var _accept_fresh_joins: bool = true
var _local_sequence: int = 0
var _local_identity: Dictionary = {}
var _peer_identities: Dictionary = {}
var _player_peers: Dictionary = {}
## Host-only reservation data. Tokens never enter a broadcast or checkpoint.
var _reserved_players: Dictionary = {}
var _pending_peers: Dictionary = {}
var _rejected_peers: Dictionary = {}
var _requested_resume: Dictionary = {}
var _last_sequences: Dictionary = {}
var _commands: Array[Dictionary] = []
var _rejections: Array[Dictionary] = []
var _command_results: Array[Dictionary] = []
var _baseline_sent_count: int = 0
var _baseline_received_count: int = 0
var _baseline_applied_count: int = 0
var _baseline_tick: int = -1
var _applied_baseline_tick: int = -1
var _received_baseline: Dictionary = {}
var _baseline_rejections: Dictionary = {}
var _was_connected: bool = false
var _last_close_reason: String = ""
var _closed_emitted: bool = false

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
	# Keep one transport slot outside the authoritative room capacity so a full
	# room can still accept the next handshake long enough to return room_full.
	# The session's seat checks below remain the authority for actual admission.
	var remote_capacity: int = maxi(seats - 1 + JOIN_REJECTION_SLOTS, 1)
	var peer := ENetMultiplayerPeer.new()
	var error: int = peer.create_server(port, remote_capacity, MAX_CHANNELS)
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
	_next_player_serial = 1
	var host_identity := _make_identity(SERVER_PEER_ID, 1, INITIAL_LIFE_ID, _next_player_serial)
	_peer_identities[SERVER_PEER_ID] = host_identity
	_player_peers[StringName(host_identity["player_id"])] = SERVER_PEER_ID
	_last_sequences[StringName(host_identity["player_id"])] = 0
	_local_identity = host_identity.duplicate(true)
	return OK

## Pass a saved get_local_identity() as resume to reclaim the same player.
## Existing join(address, port) calls remain a fresh join.
func join(address: String, port: int, resume: Dictionary = {}) -> int:
	if not is_inside_tree():
		return ERR_UNCONFIGURED
	if _is_active:
		return ERR_ALREADY_IN_USE
	if address.is_empty() or port <= 0 or port > 65535:
		return ERR_INVALID_PARAMETER
	var peer := ENetMultiplayerPeer.new()
	var error: int = peer.create_client(address, port, MAX_CHANNELS)
	if error != OK:
		return error
	_reset_state()
	_is_host = false
	_requested_resume = resume.duplicate(true)
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
	_close_transport()
	_reset_state()
	_last_close_reason = "stopped"
	if was_active:
		_emit_session_closed()

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

## Ended rooms still accept a reserved player's authenticated reconnect so
## they can receive the final result, but no new contestant may enter.
func set_fresh_joins_allowed(allowed: bool) -> void:
	if _is_host: _accept_fresh_joins = allowed

func get_player_count() -> int:
	return _peer_identities.size()

## Active and reserved seats both count against the match limit.
func get_occupied_seat_count() -> int:
	return _peer_identities.size() + _reserved_players.size()

func is_player_reserved(player_id: StringName) -> bool:
	return _is_host and _reserved_players.has(player_id)

func is_player_online(player_id: StringName) -> bool:
	return _player_peers.has(player_id)

func get_reserved_player_ids() -> Array[StringName]:
	var result: Array[StringName] = []
	if _is_host:
		for player_id: StringName in _reserved_players:
			result.append(player_id)
	return result

## Bridge may call this each authority step; the session also checks in _process.
## Monotonic host time is used so paused gameplay cannot extend a reservation.
func expire_reserved_players() -> void:
	if not _is_host or not _is_active:
		return
	var now: int = Time.get_ticks_msec()
	for player_id: StringName in _reserved_players.keys():
		if now < int(_reserved_players[player_id].get("expires_at_msec", 0)):
			continue
		_reserved_players.erase(player_id)
		_last_sequences.erase(player_id)
		player_reservation_expired.emit(String(player_id))

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
	if life_id < INITIAL_LIFE_ID:
		return false
	if not _player_peers.has(player_id):
		if not _reserved_players.has(player_id):
			return false
		var reservation: Dictionary = _reserved_players[player_id]
		var offline_identity: Dictionary = reservation["identity"]
		if life_id <= int(offline_identity.get("life_id", 0)):
			return false
		offline_identity["life_id"] = life_id
		_last_sequences[player_id] = 0
		return true
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

## Host-only transport entry for authoritative snapshot batches. The bridge
## owns the payload; NetworkSession only checks the sender side and channel.
func broadcast_snapshot_batch(batch: Dictionary) -> int:
	if not _is_host or not is_active() or batch.is_empty():
		return ERR_UNCONFIGURED
	if int(batch.get("match_epoch", -1)) != _match_epoch:
		return ERR_INVALID_PARAMETER
	if int(batch.get("server_tick", -1)) < 0:
		return ERR_INVALID_PARAMETER
	if not (batch.get("players", null) is Dictionary):
		return ERR_INVALID_PARAMETER
	_rpc_snapshot_batch.rpc(batch.duplicate(true))
	return OK

## Host-only reliable full-baseline delivery. The bridge builds the payload at a
## single authority tick; NetworkSession only validates the envelope and sends
## it on the reliable baseline channel before any later live traffic matters.
func send_baseline(peer_id: int, baseline: Dictionary) -> int:
	if not _is_host or not is_active() or baseline.is_empty():
		return ERR_UNCONFIGURED
	if peer_id <= SERVER_PEER_ID or not _peer_identities.has(peer_id):
		return ERR_INVALID_PARAMETER
	if int(baseline.get("match_epoch", -1)) != _match_epoch:
		return ERR_INVALID_PARAMETER
	var tick := int(baseline.get("baseline_tick", baseline.get("server_tick", -1)))
	if tick < 0:
		return ERR_INVALID_PARAMETER
	if not (baseline.get("players", null) is Dictionary):
		return ERR_INVALID_PARAMETER
	var payload: Dictionary = baseline.duplicate(true)
	payload["baseline_tick"] = tick
	payload["server_tick"] = tick
	_rpc_baseline.rpc_id(peer_id, payload)
	_baseline_sent_count += 1
	return OK

func get_baseline_send_count() -> int:
	return _baseline_sent_count

func has_baseline() -> bool:
	return _baseline_received_count > 0

func get_baseline_received_count() -> int:
	return _baseline_received_count

func get_baseline_applied_count() -> int:
	return _baseline_applied_count

func get_baseline_tick() -> int:
	return _baseline_tick

func get_applied_baseline_tick() -> int:
	return _applied_baseline_tick

func get_baseline() -> Dictionary:
	if _received_baseline.is_empty():
		return {}
	return _received_baseline.duplicate(true)

func get_baseline_rejected_count(reason: String) -> int:
	return int(_baseline_rejections.get(reason, 0))

func get_last_close_reason() -> String:
	return _last_close_reason

## Called by the bridge after the replica successfully applies the received
## baseline. It keeps transport observation and gameplay application distinct.
func mark_baseline_applied(baseline: Dictionary) -> bool:
	if _is_host or not _is_active or _received_baseline.is_empty():
		return false
	var tick := int(baseline.get("baseline_tick", baseline.get("server_tick", -1)))
	if tick != _baseline_tick or tick <= _applied_baseline_tick:
		return false
	_applied_baseline_tick = tick
	_baseline_applied_count += 1
	baseline_applied.emit(baseline.duplicate(true))
	return true

# Fire and movement share sequence numbering, so use one reliable ordered stream.
# A later movement packet must never overtake and invalidate an earlier fire.
# Tradeoff: packet loss delays movement; split sequence domains in a later ticket.
@rpc("any_peer", "call_remote", "reliable", BASELINE_CHANNEL)
func _rpc_join_request(resume: Dictionary) -> void:
	if not _is_host or not _is_active:
		return
	var sender: int = int(multiplayer.get_remote_sender_id())
	if sender <= SERVER_PEER_ID or not _pending_peers.has(sender) or _peer_identities.has(sender):
		return
	_pending_peers.erase(sender)
	expire_reserved_players()
	if resume.is_empty():
		_accept_fresh_join(sender)
	else:
		_accept_resume(sender, resume)

@rpc("authority", "call_remote", "reliable", BASELINE_CHANNEL)
func _rpc_join_rejected(reason: String) -> void:
	if _is_host or not _is_active or int(multiplayer.get_remote_sender_id()) != SERVER_PEER_ID:
		return
	_is_active = false
	_was_connected = false
	_last_close_reason = reason
	join_failed.emit(reason)
	_close_transport()
	_emit_session_closed()

@rpc("any_peer", "call_remote", "reliable", COMMAND_CHANNEL)
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
	var token := String(identity.get("reconnect_token", ""))
	if player_id.is_empty() or peer_id <= 0 or epoch <= 0 or life_id < INITIAL_LIFE_ID \
			or token.length() != 64:
		return
	_local_identity = identity.duplicate(true)
	_match_epoch = epoch
	_local_sequence = 0
	_requested_resume.clear()
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

@rpc("authority", "call_remote", "unreliable_ordered", SNAPSHOT_CHANNEL)
func _rpc_snapshot_batch(batch: Dictionary) -> void:
	if _is_host or not _is_active or _local_identity.is_empty():
		return
	if int(multiplayer.get_remote_sender_id()) != SERVER_PEER_ID:
		return
	if not batch.has("match_epoch") or not batch.has("server_tick") or not (batch.get("players", null) is Dictionary):
		return
	snapshot_batch_received.emit(batch.duplicate(true))

@rpc("authority", "call_remote", "reliable", BASELINE_CHANNEL)
func _rpc_baseline(baseline: Dictionary) -> void:
	if _is_host or not _is_active or _local_identity.is_empty():
		return
	if int(multiplayer.get_remote_sender_id()) != SERVER_PEER_ID:
		return
	var tick := int(baseline.get("baseline_tick", baseline.get("server_tick", -1)))
	if int(baseline.get("match_epoch", -1)) != _match_epoch:
		_reject_baseline(REJECT_STALE_EPOCH, tick)
		return
	if tick < 0 or not (baseline.get("players", null) is Dictionary):
		_reject_baseline(REJECT_INVALID_BASELINE, tick)
		return
	if _baseline_received_count > 0:
		var reason := REJECT_DUPLICATE_BASELINE if tick >= _baseline_tick else REJECT_STALE_BASELINE
		_reject_baseline(reason, tick)
		return
	_baseline_tick = tick
	_received_baseline = baseline.duplicate(true)
	_received_baseline["baseline_tick"] = tick
	_received_baseline["server_tick"] = tick
	_baseline_received_count += 1
	baseline_received.emit(_received_baseline.duplicate(true))

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

func _reject_baseline(reason: String, tick: int) -> void:
	_baseline_rejections[reason] = int(_baseline_rejections.get(reason, 0)) + 1
	var result := {
		"accepted": false,
		"applied": false,
		"reason": reason,
		"tick": tick,
	}
	baseline_rejected.emit(result)

func _make_identity(peer_id: int, seat: int, life_id: int, player_serial: int) -> Dictionary:
	return {
		"player_id": "player_%d" % player_serial,
		"peer_id": peer_id,
		"seat": seat,
		"match_epoch": _match_epoch,
		"life_id": life_id,
	}

func _new_reconnect_token() -> String:
	var bytes: PackedByteArray = Crypto.new().generate_random_bytes(32)
	return bytes.hex_encode() if bytes.size() == 32 else ""

func _free_seat() -> int:
	for seat in range(2, _max_seats + 1):
		var used := false
		for identity_variant: Variant in _peer_identities.values():
			if int(identity_variant.get("seat", 0)) == seat:
				used = true
				break
		if used: continue
		for reservation_variant: Variant in _reserved_players.values():
			var identity: Dictionary = reservation_variant.get("identity", {})
			if int(identity.get("seat", 0)) == seat:
				used = true
				break
		if not used: return seat
	return 0

func _accept_fresh_join(peer_id: int) -> void:
	if not _accept_fresh_joins:
		_reject_join(peer_id, "match_ended")
		return
	if get_occupied_seat_count() >= _max_seats:
		_reject_join(peer_id, "room_full")
		return
	var seat := _free_seat()
	if seat == 0:
		_reject_join(peer_id, "room_full")
		return
	var token := _new_reconnect_token()
	if token.is_empty():
		_reject_join(peer_id, "credential_unavailable")
		return
	_next_player_serial += 1
	var identity := _make_identity(peer_id, seat, INITIAL_LIFE_ID, _next_player_serial)
	identity["reconnect_token"] = token
	var player_id := StringName(String(identity["player_id"]))
	_peer_identities[peer_id] = identity
	_player_peers[player_id] = peer_id
	_last_sequences[player_id] = 0
	_rpc_assign_identity.rpc_id(peer_id, identity.duplicate(true))
	player_joined.emit(peer_id, String(player_id))

func _accept_resume(peer_id: int, resume: Dictionary) -> void:
	var player_id := StringName(String(resume.get("player_id", "")))
	var token := String(resume.get("reconnect_token", ""))
	if player_id == &"" or token.length() != 64 \
			or int(resume.get("match_epoch", -1)) != _match_epoch \
			or not _reserved_players.has(player_id):
		_reject_join(peer_id, "invalid_reconnect_credential")
		return
	var reservation: Dictionary = _reserved_players[player_id]
	var previous: Dictionary = reservation["identity"]
	if token != String(previous.get("reconnect_token", "")) \
			or int(resume.get("seat", -1)) != int(previous.get("seat", -2)):
		_reject_join(peer_id, "invalid_reconnect_credential")
		return
	var replacement_token := _new_reconnect_token()
	if replacement_token.is_empty():
		_reject_join(peer_id, "credential_unavailable")
		return
	var identity: Dictionary = previous.duplicate(true)
	identity["peer_id"] = peer_id
	identity["reconnect_token"] = replacement_token
	_reserved_players.erase(player_id)
	_peer_identities[peer_id] = identity
	_player_peers[player_id] = peer_id
	_last_sequences[player_id] = 0
	_rpc_assign_identity.rpc_id(peer_id, identity.duplicate(true))
	player_resumed.emit(peer_id, String(player_id))

func _reject_join(peer_id: int, reason: String) -> void:
	_rpc_join_rejected.rpc_id(peer_id, reason)
	# Give the reliable reason a chance to leave. The pending eviction belongs
	# to this session and is discarded if the peer leaves or the session resets.
	_rejected_peers[peer_id] = Time.get_ticks_msec() + 200

func _disconnect_rejected_peer(peer_id: int) -> void:
	if not _is_host or not is_active() or _peer_identities.has(peer_id):
		return
	var peer: MultiplayerPeer = multiplayer.multiplayer_peer
	if peer != null:
		peer.disconnect_peer(peer_id)

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
	_pending_peers[peer_id] = Time.get_ticks_msec() + JOIN_HANDSHAKE_MSEC

func _on_peer_disconnected(peer_id: int) -> void:
	if not _is_host:
		return
	_pending_peers.erase(peer_id)
	_rejected_peers.erase(peer_id)
	if not _peer_identities.has(peer_id):
		return
	var identity: Dictionary = _peer_identities[peer_id]
	var player_id := String(identity.get("player_id", ""))
	_peer_identities.erase(peer_id)
	_player_peers.erase(StringName(player_id))
	_last_sequences.erase(StringName(player_id))
	# Once the socket is gone, no already-accepted command may still drive the
	# retained actor. The bridge also clears continuous movement and guard input.
	var remaining: Array[Dictionary] = []
	for record: Dictionary in _commands:
		if int(record.get("peer_id", 0)) != peer_id:
			remaining.append(record)
	_commands = remaining
	_reserved_players[StringName(player_id)] = {
		"identity": identity.duplicate(true),
		"expires_at_msec": Time.get_ticks_msec() + RECONNECT_WINDOW_MSEC,
	}
	player_left.emit(peer_id, player_id)

func _on_connected_to_server() -> void:
	_was_connected = true
	_rpc_join_request.rpc_id(SERVER_PEER_ID, _requested_resume.duplicate(true))

func _on_connection_failed() -> void:
	if _is_host:
		return
	if not _is_active:
		return
	_is_active = false
	_was_connected = false
	_close_transport()
	_last_close_reason = "connection_failed"
	join_failed.emit("connection_failed")

func _on_server_disconnected() -> void:
	if _is_host:
		return
	_handle_server_disconnect("server_disconnected")

func _process(_delta: float) -> void:
	if _is_active and _is_host:
		expire_reserved_players()
		var now := Time.get_ticks_msec()
		for peer_id: int in _rejected_peers.keys():
			if now >= int(_rejected_peers[peer_id]):
				_rejected_peers.erase(peer_id)
				_disconnect_rejected_peer(peer_id)
		for peer_id: int in _pending_peers.keys():
			if now >= int(_pending_peers[peer_id]):
				_pending_peers.erase(peer_id)
				_reject_join(peer_id, "join_timeout")
		return
	if not _is_active or _is_host or not _was_connected:
		return
	if not is_inside_tree():
		return
	var api: MultiplayerAPI = multiplayer
	var peer: MultiplayerPeer = api.multiplayer_peer
	if peer == null:
		_handle_server_disconnect("transport_lost")
		return
	if peer.get_connection_status() == MultiplayerPeer.CONNECTION_DISCONNECTED:
		_handle_server_disconnect("connection_lost")

func _handle_server_disconnect(reason: String) -> void:
	if _is_host or not _is_active:
		return
	_is_active = false
	_was_connected = false
	_close_transport()
	_last_close_reason = reason
	_emit_session_closed()

func _close_transport() -> void:
	if not is_inside_tree():
		return
	var api: MultiplayerAPI = multiplayer
	var peer: MultiplayerPeer = api.multiplayer_peer
	if peer == null:
		return
	peer.close()
	api.multiplayer_peer = null

func _emit_session_closed() -> void:
	if _closed_emitted:
		return
	_closed_emitted = true
	session_closed.emit()

func _reset_state() -> void:
	_match_epoch = 0
	_max_seats = MAX_SEATS
	_local_port = 0
	_next_player_serial = 0
	_accept_fresh_joins = true
	_local_sequence = 0
	_local_identity = {}
	_peer_identities.clear()
	_player_peers.clear()
	_reserved_players.clear()
	_pending_peers.clear()
	_rejected_peers.clear()
	_requested_resume.clear()
	_last_sequences.clear()
	_commands.clear()
	_rejections.clear()
	_command_results.clear()
	_baseline_sent_count = 0
	_baseline_received_count = 0
	_baseline_applied_count = 0
	_baseline_tick = -1
	_applied_baseline_tick = -1
	_received_baseline = {}
	_baseline_rejections.clear()
	_was_connected = false
	_last_close_reason = ""
	_closed_emitted = false

func _exit_tree() -> void:
	if _is_active:
		stop()

func broadcast_combat_state(packet: Dictionary) -> int:
	if not _is_host or not is_active():
		return ERR_UNCONFIGURED
	if int(packet.get("match_epoch", -1)) != _match_epoch:
		return ERR_INVALID_PARAMETER
	_rpc_combat_state.rpc(packet)
	return OK

@rpc("authority", "call_remote", "reliable", BASELINE_CHANNEL)
func _rpc_combat_state(packet: Dictionary) -> void:
	if _is_host or not is_active() or multiplayer.get_remote_sender_id() != SERVER_PEER_ID:
		return
	if int(packet.get("match_epoch", -1)) != _match_epoch:
		return
	combat_state_received.emit(packet.duplicate(true))
