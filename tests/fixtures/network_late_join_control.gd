extends Node

## Fixture-only reliable control plane for the Ticket 02B2A two-process test.
## The late-joining client reports that it has applied the baseline and observed
## a strictly higher snapshot; that report tells the host when it is safe to
## close. Authoritative state never travels on this node.

signal join_progress_received(progress: Dictionary)

const SERVER_PEER_ID: int = 1

var log_path := ""

func report_join_progress(progress: Dictionary) -> Error:
	_log("sending reliable post-baseline progress to peer %d" % SERVER_PEER_ID)
	return rpc_id(SERVER_PEER_ID, "_rpc_join_progress", progress)

@rpc("any_peer", "call_remote", "reliable")
func _rpc_join_progress(progress: Dictionary) -> void:
	var sender := int(multiplayer.get_remote_sender_id())
	_log("received post-baseline progress from peer %d" % sender)
	if not multiplayer.is_server() or sender <= SERVER_PEER_ID:
		return
	join_progress_received.emit(progress.duplicate(true))

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
