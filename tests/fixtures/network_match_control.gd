extends Node

## Fixture-only reliable control plane for the Ticket 02B1 two-process test.
## It carries the orchestration handshake (target tick, client completion and
## finish acknowledgement) on ENet's reliable channel. Snapshot data always
## travels through NetworkSession's unreliable_ordered snapshot channel; this
## node never carries authoritative state.

signal target_tick_announced(tick: int)
signal client_done_received(tick: int)
signal finish_acknowledged()

const SERVER_PEER_ID: int = 1

var log_path := ""

func announce_target_tick(peer_id: int, tick: int) -> Error:
	_log("sending reliable target tick %d to peer %d" % [tick, peer_id])
	return rpc_id(peer_id, "_rpc_target_tick", tick)

func report_client_done(tick: int) -> Error:
	_log("sending reliable client-done tick %d to peer %d" % [tick, SERVER_PEER_ID])
	return rpc_id(SERVER_PEER_ID, "_rpc_client_done", tick)

func acknowledge_finish(peer_id: int) -> Error:
	_log("sending reliable finish acknowledgement to peer %d" % peer_id)
	return rpc_id(peer_id, "_rpc_finish_ack")

@rpc("authority", "call_remote", "reliable")
func _rpc_target_tick(tick: int) -> void:
	var sender := int(multiplayer.get_remote_sender_id())
	_log("received target tick %d from peer %d" % [tick, sender])
	if sender != SERVER_PEER_ID:
		return
	target_tick_announced.emit(tick)

@rpc("any_peer", "call_remote", "reliable")
func _rpc_client_done(tick: int) -> void:
	var sender := int(multiplayer.get_remote_sender_id())
	_log("received client-done tick %d from peer %d" % [tick, sender])
	if not multiplayer.is_server() or sender <= SERVER_PEER_ID:
		return
	client_done_received.emit(tick)

@rpc("authority", "call_remote", "reliable")
func _rpc_finish_ack() -> void:
	var sender := int(multiplayer.get_remote_sender_id())
	_log("received finish acknowledgement from peer %d" % sender)
	if sender != SERVER_PEER_ID:
		return
	finish_acknowledged.emit()

func _log(message: String) -> void:
	var line := "[%d] CONTROL %s (path=%s)" % [Time.get_ticks_msec(), message, String(get_path())]
	print(line)
	if log_path.is_empty():
		return
	var file: FileAccess = null
	if FileAccess.file_exists(log_path):
		file = FileAccess.open(log_path, FileAccess.READ_WRITE)
		if file != null:
			file.seek_end()
	else:
		file = FileAccess.open(log_path, FileAccess.WRITE)
	if file == null:
		return
	file.store_line(line)
	file.close()
