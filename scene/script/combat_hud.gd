extends CanvasLayer
@export var selected_style: StyleBoxFlat
@export var idle_style: StyleBoxFlat
var _actor: Node2D
var _controller: Node
@onready var guard_bar: ProgressBar = %GuardBar
@onready var gun_slot: PanelContainer = %GunSlot
@onready var sword_slot: PanelContainer = %SwordSlot

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
	show()

func unbind_actor() -> void:
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
