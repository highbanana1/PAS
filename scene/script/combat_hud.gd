extends CanvasLayer

@export var selected_style: StyleBoxFlat
@export var idle_style: StyleBoxFlat
var _controller
@onready var guard_bar: ProgressBar = %GuardBar
@onready var gun_slot: PanelContainer = %GunSlot
@onready var sword_slot: PanelContainer = %SwordSlot


func bind_player(player: Player) -> void:
	hide()
	if not is_instance_valid(player) or not player.is_locally_controlled:
		return
	_controller = player.get_node("WeaponController")
	_controller.weapon_changed.connect(_update_weapon)
	_controller.guard_changed.connect(_update_guard)
	_update_weapon(_controller.current_weapon)
	_update_guard(_controller.guard_value, _controller.max_guard)
	show()


func _update_weapon(weapon: int) -> void:
	gun_slot.add_theme_stylebox_override("panel", selected_style if weapon == 0 else idle_style)
	sword_slot.add_theme_stylebox_override("panel", selected_style if weapon == 1 else idle_style)
	%GunIcon.modulate = Color.WHITE if weapon == 0 else Color(0.6, 0.6, 0.6, 0.7)
	%SwordIcon.modulate = Color.WHITE if weapon == 1 else Color(0.6, 0.6, 0.6, 0.7)


func _update_guard(value: float, maximum: float) -> void:
	guard_bar.max_value = maximum
	guard_bar.value = value
