extends CanvasLayer
@export var selected_style: StyleBoxFlat
@export var idle_style: StyleBoxFlat
var _actor: Node2D
var _items: Node
var _icons: Array = []
var _reserves: Array = []
var _counts: Array = []
var _controller: Node
@onready var guard_bar: ProgressBar = %GuardBar
@onready var gun_slot: PanelContainer = %GunSlot
@onready var sword_slot: PanelContainer = %SwordSlot
@onready var _bottom_bar: HBoxContainer = %BottomBar

func _ready() -> void:
	_setup_item_slots()
	get_viewport().size_changed.connect(_resize_hotbar)
	_resize_hotbar()

func _resize_hotbar() -> void:
	var width := clampf(roundf(get_viewport().get_visible_rect().size.x * 0.1), 56.0, 80.0)
	var height := roundf(width * 0.875)
	for slot: Control in [gun_slot, sword_slot, %ItemSlot1, %ItemSlot2, %ItemSlot3]:
		slot.custom_minimum_size = Vector2(width, height)
	_bottom_bar.offset_top = -20.0 - height - 18.0


func bind_player(player: Node2D) -> void:
	bind_actor(player)

func bind_actor(actor: Node2D) -> void:
	unbind_actor()
	if not is_instance_valid(actor) or actor.get("is_locally_controlled") == false or not actor.has_method("get_weapon_controller"): return
	_actor = actor
	_controller = actor.get_weapon_controller()
	_controller.weapon_changed.connect(_update_weapon)
	_controller.guard_changed.connect(_update_guard)
	_actor.tree_exiting.connect(unbind_actor)
	_update_weapon(_controller.current_weapon)
	_update_guard(_controller.guard_value, _controller.max_guard)
	if actor.has_method("get_health_item_component"):
		_items = actor.get_health_item_component()
		_items.changed.connect(_update_items)
	_update_items()
	show()

func unbind_actor() -> void:
	if is_instance_valid(_items) and _items.changed.is_connected(_update_items): _items.changed.disconnect(_update_items)
	_items = null
	if is_instance_valid(_controller):
		if _controller.weapon_changed.is_connected(_update_weapon): _controller.weapon_changed.disconnect(_update_weapon)
		if _controller.guard_changed.is_connected(_update_guard): _controller.guard_changed.disconnect(_update_guard)
	if is_instance_valid(_actor) and _actor.tree_exiting.is_connected(unbind_actor): _actor.tree_exiting.disconnect(unbind_actor)
	_actor = null
	_controller = null
	hide()

func _update_weapon(weapon: int) -> void:
	gun_slot.add_theme_stylebox_override("panel", selected_style if weapon == 0 else idle_style)
	sword_slot.add_theme_stylebox_override("panel", selected_style if weapon == 1 else idle_style)
	%GunIcon.modulate = Color.WHITE if weapon == 0 else Color(0.6, 0.6, 0.6, 0.7)
	%SwordIcon.modulate = Color.WHITE if weapon == 1 else Color(0.6, 0.6, 0.6, 0.7)

func _update_guard(value: float, maximum: float) -> void:
	guard_bar.max_value = maximum
	guard_bar.value = value

func _setup_item_slots() -> void:
	_icons = [%HealthItemIcon]; _reserves = [%HealthItemProgress]; _counts = [%HealthItemCount]
	for index in range(1,3):
		var slot: PanelContainer = %ItemSlot2 if index == 1 else %ItemSlot3
		var box := VBoxContainer.new(); box.add_theme_constant_override("separation",1); slot.add_child(box); box.mouse_filter = Control.MOUSE_FILTER_IGNORE
		var icon := TextureRect.new(); icon.custom_minimum_size = Vector2(30,20)
		icon.size_flags_vertical = Control.SIZE_EXPAND_FILL; icon.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
		icon.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED; icon.mouse_filter = Control.MOUSE_FILTER_IGNORE
		box.add_child(icon); _icons.append(icon)
		var reserve := ProgressBar.new(); reserve.custom_minimum_size = Vector2(0,4)
		reserve.mouse_filter = Control.MOUSE_FILTER_IGNORE; reserve.show_percentage = false; reserve.step = 0.01
		for style in ["background","fill"]: reserve.add_theme_stylebox_override(style,%HealthItemProgress.get_theme_stylebox(style))
		box.add_child(reserve); _reserves.append(reserve)
		var footer := HBoxContainer.new(); footer.mouse_filter = Control.MOUSE_FILTER_IGNORE; box.add_child(footer)
		var key := Label.new(); key.text = str(index + 3); key.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		key.mouse_filter = Control.MOUSE_FILTER_IGNORE; key.add_theme_font_override("font",%HealthItemCount.get_theme_font("font")); key.add_theme_font_size_override("font_size",12); footer.add_child(key)
		var count := Label.new(); count.mouse_filter = Control.MOUSE_FILTER_IGNORE; count.add_theme_font_override("font",%HealthItemCount.get_theme_font("font")); count.add_theme_font_size_override("font_size",12); footer.add_child(count); _counts.append(count)

func _update_items() -> void:
	for index in range(3):
		var slot: Control = [%ItemSlot1,%ItemSlot2,%ItemSlot3][index]
		var has_item: bool = is_instance_valid(_items) and index < _items.items.size()
		var is_selected: bool = is_instance_valid(_items) and _items.selected and _items.selected_index == index
		slot.add_theme_stylebox_override("panel",selected_style if is_selected else idle_style)
		_icons[index].visible = has_item; _reserves[index].visible = false; _counts[index].text = "1" if has_item else ""
		if has_item:
			var item = _items.items[index]; var atlas := AtlasTexture.new()
			atlas.atlas = item.icon; atlas.region = item.icon_region; _icons[index].texture = atlas
			_reserves[index].visible = item.supports_continuous_use()
			_reserves[index].max_value = item.capacity; _reserves[index].value = item.remaining
