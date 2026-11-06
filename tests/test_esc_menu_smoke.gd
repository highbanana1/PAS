extends SceneTree

func _initialize() -> void:
	_run.call_deferred()

func _run() -> void:
	await _check_scene("res://scene/main.tscn", false)
	await _check_scene("res://scene/pvp_main.tscn", true)
	await _check_online_entry()
	print("ESC_MENU_SMOKE=PASS")
	quit(0)

func _check_scene(path: String, online: bool) -> void:
	var scene: PackedScene = load(path)
	assert(scene != null)
	var world: Node = scene.instantiate()
	root.add_child(world)
	await process_frame
	var menu: EscMenu = world.get_node("EscMenu")
	var panel: PanelContainer = menu.get("_panel")
	assert(not panel.visible)
	var escape := InputEventKey.new()
	escape.keycode = KEY_ESCAPE
	escape.pressed = true
	Input.parse_input_event(escape)
	await process_frame
	assert(panel.visible, "Escape did not open the menu")
	assert(not paused, "Escape paused the shared world")
	var button: Button = menu.get("_lobby_button")
	assert(button.text == ("联机房间" if online else "进入联机模式"))
	if online:
		var lobby: CanvasLayer = world.get_node("PvPLobby")
		button.pressed.emit()
		assert(lobby.visible and not panel.visible, "Online room button did not show lobby")
	else:
		var brightness: ColorRect = menu.get("_brightness_cover")
		assert(brightness != null)
		_check_settings(menu)
	Input.parse_input_event(escape)
	await process_frame
	if online:
		assert(panel.visible, "Escape did not reopen the menu")
	else:
		assert(not panel.visible, "Escape did not close the menu")
	world.queue_free()
	await process_frame

func _check_settings(menu: EscMenu) -> void:
	var path := "user://pas_display.cfg"
	var existed := FileAccess.file_exists(path)
	var previous := FileAccess.get_file_as_bytes(path) if existed else PackedByteArray()
	var previous_volume := AudioServer.get_bus_volume_db(0)
	var previous_mute := AudioServer.is_bus_mute(0)
	menu._on_brightness_changed(0.75)
	menu._on_volume_changed(0.5)
	var settings := ConfigFile.new()
	var loaded := settings.load(path) == OK
	var brightness_ok := loaded and is_equal_approx(float(settings.get_value("display", "brightness", 0.0)), 0.75)
	var volume_ok := loaded and is_equal_approx(float(settings.get_value("audio", "master", 0.0)), 0.5)
	if existed:
		var file := FileAccess.open(path, FileAccess.WRITE)
		file.store_buffer(previous)
		file.close()
	else:
		DirAccess.remove_absolute(ProjectSettings.globalize_path(path))
	AudioServer.set_bus_volume_db(0, previous_volume)
	AudioServer.set_bus_mute(0, previous_mute)
	assert(brightness_ok and volume_ok, "Display and audio settings were not persisted")

func _check_online_entry() -> void:
	var scene: PackedScene = load("res://scene/main.tscn")
	var world := scene.instantiate()
	root.add_child(world)
	current_scene = world
	await process_frame
	var menu: EscMenu = world.get_node("EscMenu")
	var button: Button = menu.get("_lobby_button")
	button.pressed.emit()
	await process_frame
	await process_frame
	assert(current_scene != null and current_scene.name == "PvPMain", "Online entry did not open PvP scene")
	current_scene.queue_free()
	current_scene = null
	await process_frame
