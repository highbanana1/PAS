extends Node2D

## Separate multiplayer entry. The offline Main scene remains untouched.
const PlayerScene: PackedScene = preload("res://scene/maincharac.tscn")
const SessionScript = preload("res://scene/script/network/network_session.gd")
const BridgeScript = preload("res://scene/script/network/match_network_bridge.gd")

@export_range(1, 65535, 1) var listen_port: int = 24577
@export_range(1, 16, 1) var max_players: int = 16

var _session: NetworkSession
var _bridge: MatchNetworkBridge
var _actors: Dictionary = {}
var _saved_identity: Dictionary = {}
var _last_address: String = "127.0.0.1"
var _address: LineEdit
var _status: Label
var _host_button: Button
var _join_button: Button
var _reconnect_button: Button
var _start_button: Button
var _spectator_camera: Camera2D
var _spectator_target: String = ""

func _ready() -> void:
	# Candidate stars are invisible until the host freezes the opening roster.
	for star: Area2D in [$WinningPoint, $StarCandidate2, $StarCandidate3, $StarCandidate4]:
		star.set_network_controlled(true)
		star.apply_network_star({})
	$wtable.set_network_controlled(true)
	$UILayer.unbind_actor()
	$DeathScreen.unbind_actor()
	$CombatHUD.unbind_actor()
	_spectator_camera = Camera2D.new()
	_spectator_camera.name = "SpectatorCamera"
	_spectator_camera.enabled = false
	add_child(_spectator_camera)
	_build_lobby()

func _process(_delta: float) -> void:
	if not is_instance_valid(_bridge) or not is_instance_valid(_session): return
	var local_id := String(_session.get_local_identity().get("player_id", ""))
	if local_id.is_empty() or not _actors.has(local_id): return
	var local_state := _player_state(local_id)
	if not bool(local_state.get("extracted", false)):
		if _spectator_camera.enabled:
			_spectator_camera.enabled = false
			var own_camera := _actors[local_id].get_node_or_null("Camera2D") as Camera2D
			if own_camera != null:
				own_camera.enabled = true
				own_camera.make_current()
		return
	var own_camera := _actors[local_id].get_node_or_null("Camera2D") as Camera2D
	if own_camera != null: own_camera.enabled = false
	if not _spectator_camera.enabled:
		_spectator_camera.enabled = true
		_spectator_camera.make_current()
	if not _can_spectate(_spectator_target, local_id):
		_cycle_spectator(local_id)
	if _actors.has(_spectator_target):
		_spectator_camera.global_position = _actors[_spectator_target].global_position

func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventKey and event.pressed and not event.echo and event.keycode == KEY_TAB:
		if is_instance_valid(_spectator_camera) and _spectator_camera.enabled and is_instance_valid(_session):
			_cycle_spectator(String(_session.get_local_identity().get("player_id", "")))
			get_viewport().set_input_as_handled()

func _player_state(player_id: String) -> Dictionary:
	if not is_instance_valid(_bridge): return {}
	if _bridge.is_host_authority():
		return _bridge.get_authority().get_snapshot(StringName(player_id))
	return _bridge.get_replica_state(StringName(player_id))

func _can_spectate(player_id: String, local_id: String) -> bool:
	if player_id.is_empty() or player_id == local_id or not _actors.has(player_id): return false
	return not bool(_player_state(player_id).get("extracted", false))

func _cycle_spectator(local_id: String) -> void:
	var candidates: Array[String] = []
	for raw_id: Variant in _actors.keys():
		var id := String(raw_id)
		if _can_spectate(id, local_id): candidates.append(id)
	candidates.sort()
	if candidates.is_empty():
		_spectator_target = ""
		return
	var index := candidates.find(_spectator_target)
	_spectator_target = candidates[(index + 1) % candidates.size()]

func _build_lobby() -> void:
	var layer := CanvasLayer.new()
	layer.name = "PvPLobby"
	layer.layer = 10
	add_child(layer)
	var panel := PanelContainer.new()
	panel.set_anchors_preset(Control.PRESET_TOP_LEFT)
	panel.position = Vector2(16, 16)
	panel.custom_minimum_size = Vector2(230, 0)
	layer.add_child(panel)
	var list := VBoxContainer.new()
	list.add_theme_constant_override("separation", 5)
	panel.add_child(list)
	var title := Label.new()
	title.text = "PvP · 星星撤离"
	list.add_child(title)
	_address = LineEdit.new()
	_address.placeholder_text = "房主 IP"
	_address.text = _last_address
	list.add_child(_address)
	_host_button = Button.new()
	_host_button.text = "建房"
	_host_button.pressed.connect(_on_host_pressed)
	list.add_child(_host_button)
	_join_button = Button.new()
	_join_button.text = "加入"
	_join_button.pressed.connect(_on_join_pressed)
	list.add_child(_join_button)
	_reconnect_button = Button.new()
	_reconnect_button.text = "重连"
	_reconnect_button.pressed.connect(_on_reconnect_pressed)
	_reconnect_button.hide()
	list.add_child(_reconnect_button)
	_start_button = Button.new()
	_start_button.text = "房主开始"
	_start_button.pressed.connect(_on_start_pressed)
	_start_button.hide()
	list.add_child(_start_button)
	_status = Label.new()
	_status.text = "等待建房或加入 · 端口 %d" % listen_port
	list.add_child(_status)

func _make_network() -> void:
	_session = SessionScript.new()
	_session.name = "NetworkSession"
	add_child(_session)
	_bridge = BridgeScript.new()
	_bridge.name = "MatchNetworkBridge"
	_bridge.auto_bind_world = false
	add_child(_bridge)
	_session.identity_assigned.connect(_on_identity_assigned)
	_session.join_failed.connect(_on_join_failed)
	_session.player_joined.connect(_on_host_player_joined)
	_bridge.baseline_applied.connect(_on_replicas_updated)
	_bridge.replicas_updated.connect(_on_replicas_updated)
	_bridge.session_closed.connect(_on_session_closed)

func _release_network() -> void:
	if is_instance_valid(_session) and _session.is_active():
		_session.stop()
	if is_instance_valid(_bridge): _bridge.queue_free()
	if is_instance_valid(_session): _session.queue_free()
	_bridge = null
	_session = null
	for actor: Node in _actors.values():
		if is_instance_valid(actor): actor.queue_free()
	_actors.clear()
	_spectator_target = ""
	if is_instance_valid(_spectator_camera): _spectator_camera.enabled = false
	$UILayer.unbind_actor()
	$DeathScreen.unbind_actor()
	$CombatHUD.unbind_actor()
	# Both nodes and their RPC paths must be gone before creating a new session.
	await get_tree().process_frame

func _on_host_pressed() -> void:
	_set_connecting(true)
	await _release_network()
	_make_network()
	var error: int = _session.host(listen_port, {"seats": max_players})
	if error != OK or not _bridge.configure(_session):
		_status.text = "建房失败：%d" % error
		_set_connecting(false)
		return
	_bridge.bind_world(self, 0)
	var identity: Dictionary = _session.get_local_identity()
	_ensure_actor(String(identity.get("player_id", "")), true, int(identity.get("seat", 1)))
	_start_button.disabled = false
	_start_button.show()
	_status.text = "房间已建立，端口 %d · 等待玩家" % listen_port

func _on_join_pressed() -> void:
	await _join_with_identity({})

func _on_reconnect_pressed() -> void:
	if _saved_identity.is_empty(): return
	_address.text = _last_address
	await _join_with_identity(_saved_identity)

func _join_with_identity(resume: Dictionary) -> void:
	_last_address = _address.text.strip_edges()
	if _last_address.is_empty():
		_status.text = "请输入房主 IP"
		return
	_set_connecting(true)
	await _release_network()
	_make_network()
	var error: int = _session.join(_last_address, listen_port, resume)
	if error != OK or not _bridge.configure(_session):
		_status.text = "加入失败：%d" % error
		_set_connecting(false)
		return
	_bridge.bind_world(self, 0)
	_status.text = "连接 %s:%d…" % [_last_address, listen_port]

func _on_start_pressed() -> void:
	if not is_instance_valid(_bridge) or not _bridge.is_host_authority(): return
	var opening_count: int = _bridge.get_authority().get_player_ids().size()
	var quota := mini(ceili(float(opening_count) / 4.0), 4)
	_bridge.bind_world(self, quota)
	if _bridge.start_match():
		_start_button.disabled = true
		_status.text = "对局开始 · %d 人，%d 颗星星" % [opening_count, quota]
	else:
		_status.text = "开始失败，请检查房间人数和地图星星"

func _on_host_player_joined(peer_id: int, player_id: String) -> void:
	if not is_instance_valid(_bridge) or not _bridge.is_host_authority(): return
	var identity: Dictionary = _session.get_identity_for_peer(peer_id)
	_ensure_actor(player_id, false, int(identity.get("seat", 1)))
	if not _start_button.disabled:
		_status.text = "等待开始 · 已入场 %d 人" % _bridge.get_authority().get_player_ids().size()

func _on_identity_assigned(identity: Dictionary) -> void:
	_saved_identity = identity.duplicate(true)
	_ensure_actor(String(identity.get("player_id", "")), true, int(identity.get("seat", 1)))
	_status.text = "已加入，等待房主开始"

func _on_replicas_updated(_packet: Dictionary) -> void:
	if not is_instance_valid(_bridge) or _bridge.is_host_authority() or not _bridge.has_baseline(): return
	var states: Dictionary = _bridge.get_replica_states()
	var local_id := String(_session.get_local_identity().get("player_id", ""))
	for id_variant: Variant in states.keys():
		var id := String(id_variant)
		_ensure_actor(id, id == local_id, 1, states[id_variant])
	for id_variant: Variant in _actors.keys():
		var id := String(id_variant)
		if states.has(id) or id == local_id: continue
		_bridge.unbind_player(StringName(id))
		var actor: Node = _actors[id]
		_actors.erase(id)
		if is_instance_valid(actor): actor.queue_free()
	var phase := String(_bridge.get_match_state().get("phase", "waiting"))
	if phase == "running": _status.text = "对局进行中"
	elif phase == "ended": _status.text = "对局结束"

func _ensure_actor(player_id: String, local: bool, seat: int,
		state: Dictionary = {}) -> void:
	if player_id.is_empty() or _actors.has(player_id) or not is_instance_valid(_bridge): return
	var actor := PlayerScene.instantiate() as CharacterBody2D
	actor.name = "Actor_%s" % player_id
	actor.set("is_locally_controlled", local)
	actor.scale = Vector2(0.03, 0.03)
	actor.collision_mask = 297
	var spawn_x := -250.0 + float((maxi(seat, 1) - 1) % 16) * 34.0
	actor.position = state.get("position", Vector2(spawn_x, -11.0))
	var camera := actor.get_node_or_null("Camera2D") as Camera2D
	if camera != null: camera.enabled = local
	add_child(actor)
	if not _bridge.bind_actor(StringName(player_id), actor, local):
		actor.queue_free()
		return
	_actors[player_id] = actor
	if local:
		if camera != null: camera.make_current()
		$UILayer.bind_actor(actor)
		$DeathScreen.bind_actor(actor)
		$CombatHUD.bind_actor(actor)

func _on_join_failed(reason: String) -> void:
	_status.text = "加入失败：%s" % reason
	_set_connecting(false)

func _on_session_closed() -> void:
	_status.text = "连接已结束，可重新加入"
	_set_connecting(false)
	_start_button.hide()
	_reconnect_button.visible = not _saved_identity.is_empty()

func _set_connecting(connecting: bool) -> void:
	_host_button.visible = not connecting
	_join_button.visible = not connecting
	_reconnect_button.visible = not connecting and not _saved_identity.is_empty()
