class_name EscMenu
extends CanvasLayer

## Local-only overlay. It never pauses the scene tree, so multiplayer simulation continues.
const SETTINGS_PATH := "user://pas_display.cfg"
const ONLINE_SCENE := "res://scene/pvp_main.tscn"

var _panel: PanelContainer
var _brightness_cover: ColorRect
var _brightness_label: Label
var _lobby_button: Button
var _brightness := 1.0

func _ready() -> void:
	layer = 100
	_load_brightness()
	_build_brightness_cover()
	_build_menu()
	_apply_brightness()
	_panel.hide()

func _input(event: InputEvent) -> void:
	if event is InputEventKey and event.pressed and not event.echo and event.keycode == KEY_ESCAPE:
		_set_open(not _panel.visible)
		get_viewport().set_input_as_handled()

func _set_open(open: bool) -> void:
	_panel.visible = open
	if open:
		_lobby_button.grab_focus()
	else:
		get_viewport().gui_release_focus()

func _build_brightness_cover() -> void:
	var brightness_layer := CanvasLayer.new()
	brightness_layer.layer = 5
	brightness_layer.name = "DisplayBrightness"
	get_parent().call_deferred("add_child", brightness_layer)
	_brightness_cover = ColorRect.new()
	_brightness_cover.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_brightness_cover.mouse_filter = Control.MOUSE_FILTER_IGNORE
	brightness_layer.add_child(_brightness_cover)

func _build_menu() -> void:
	var backdrop := ColorRect.new()
	backdrop.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	backdrop.color = Color(0.02, 0.04, 0.08, 0.55)
	backdrop.mouse_filter = Control.MOUSE_FILTER_STOP
	add_child(backdrop)
	_panel = PanelContainer.new()
	_panel.set_anchors_and_offsets_preset(Control.PRESET_CENTER)
	_panel.custom_minimum_size = Vector2(280, 0)
	_panel.position = Vector2(-140, -125)
	var box := StyleBoxFlat.new()
	box.bg_color = Color(0.06, 0.10, 0.17, 0.96)
	box.border_color = Color(0.22, 0.62, 0.88)
	box.set_border_width_all(2)
	box.set_content_margin_all(14)
	_panel.add_theme_stylebox_override("panel", box)
	add_child(_panel)
	var items := VBoxContainer.new()
	items.add_theme_constant_override("separation", 10)
	_panel.add_child(items)
	var title := Label.new()
	title.text = "设 置"
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	items.add_child(title)
	var resume := Button.new()
	resume.text = "继续游戏"
	resume.pressed.connect(func() -> void: _set_open(false))
	items.add_child(resume)
	_brightness_label = Label.new()
	items.add_child(_brightness_label)
	var slider := HSlider.new()
	slider.min_value = 0.6
	slider.max_value = 1.4
	slider.step = 0.05
	slider.value = _brightness
	slider.value_changed.connect(_on_brightness_changed)
	items.add_child(slider)
	_lobby_button = Button.new()
	_lobby_button.text = "联机房间" if _is_online_scene() else "进入联机模式"
	_lobby_button.pressed.connect(_on_lobby_pressed)
	items.add_child(_lobby_button)
	var note := Label.new()
	note.text = "当前联机：局域网 / IP" if _is_online_scene() else "联机模式使用现有 IP 房间"
	note.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	items.add_child(note)
	backdrop.visible = false
	_panel.visibility_changed.connect(func() -> void: backdrop.visible = _panel.visible)

func _is_online_scene() -> bool:
	return get_parent().name == "PvPMain"

func _on_lobby_pressed() -> void:
	if not _is_online_scene():
		get_tree().change_scene_to_file(ONLINE_SCENE)
		return
	var lobby := get_parent().get_node_or_null("PvPLobby")
	if lobby != null:
		lobby.show()
	_set_open(false)

func _on_brightness_changed(value: float) -> void:
	_brightness = value
	_apply_brightness()
	var settings := ConfigFile.new()
	settings.set_value("display", "brightness", _brightness)
	settings.save(SETTINGS_PATH)

func _load_brightness() -> void:
	var settings := ConfigFile.new()
	if settings.load(SETTINGS_PATH) == OK:
		_brightness = clampf(float(settings.get_value("display", "brightness", 1.0)), 0.6, 1.4)

func _apply_brightness() -> void:
	if _brightness_cover == null:
		return
	if _brightness <= 1.0:
		_brightness_cover.color = Color(0, 0, 0, 1.0 - _brightness)
	else:
		_brightness_cover.color = Color(1, 1, 1, (_brightness - 1.0) * 0.45)
	if _brightness_label != null:
		_brightness_label.text = "亮度  %d%%" % roundi(_brightness * 100.0)
