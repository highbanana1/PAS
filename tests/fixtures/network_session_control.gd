extends Node

## Fixture-only reliable control plane for the Ticket 02A two-process test.
##
## This node exists only in the host/client fixture processes. It carries the
## life-change trigger and the finish/close handshake on ENet's reliable
## channel, so neither control message ever enters NetworkSession's
## authoritative gameplay command queue (which stays unreliable_ordered).
## Both fixtures add this node at the same path (/root/FixtureControl).

signal life_change_requested()
signal finish_requested()
signal finish_acknowledged()

const SERVER_PEER_ID: int = 1

var log_path := ""

func request_life_change() -> Error:
	_log("sending reliable life-change request to peer %d" % SERVER_PEER_ID)
	return rpc_id(SERVER_PEER_ID, "_rpc_request_life_change")

func request_finish() -> Error:
	_log("sending reliable finish request to peer %d" % SERVER_PEER_ID)
	return rpc_id(SERVER_PEER_ID, "_rpc_request_finish")

func acknowledge_finish(peer_id: int) -> Error:
	_log("sending reliable finish acknowledgement to peer %d" % peer_id)
	return rpc_id(peer_id, "_rpc_acknowledge_finish")

@rpc("any_peer", "call_remote", "reliable")
func _rpc_request_life_change() -> void:
	var sender := int(multiplayer.get_remote_sender_id())
	_log("received life-change request from peer %d" % sender)
	if not multiplayer.is_server() or sender <= 0:
		return
	life_change_requested.emit()

@rpc("any_peer", "call_remote", "reliable")
func _rpc_request_finish() -> void:
	var sender := int(multiplayer.get_remote_sender_id())
	_log("received finish request from peer %d" % sender)
	if not multiplayer.is_server() or sender <= 0:
		return
	finish_requested.emit()

@rpc("authority", "call_remote", "reliable")
func _rpc_acknowledge_finish() -> void:
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
