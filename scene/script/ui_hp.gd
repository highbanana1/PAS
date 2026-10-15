extends CanvasLayer
@export var bar1: TextureProgressBar
@export var bar2: TextureProgressBar
@export var bar3: TextureProgressBar
@export var single_bar_hp: float = 30.0
@export var player: Node2D
var _health: Node
var _actor: Node2D

const MAX_CELLS: int = 8
var _cells: Array[TextureProgressBar] = []

func _ready() -> void:
	_cells.assign([bar1, bar2, bar3])
	while _cells.size() < MAX_CELLS:
		var cell := bar1.duplicate() as TextureProgressBar
		cell.name = "TextureProgressBar%d" % (_cells.size() + 1)
		bar1.get_parent().add_child(cell)
		_cells.append(cell)
	for index in range(_cells.size()):
		_cells[index].position = Vector2(26 + 18 * index, 9)
		_cells[index].size = Vector2(16, 16)
		# Empty health reveals the world; keep only the border and remaining fill.
		_cells[index].texture_under = null
		_cells[index].mouse_filter = Control.MOUSE_FILTER_IGNORE
	bind_actor(player)

func get_health_cells() -> Array[TextureProgressBar]:
	return _cells.duplicate()

func bind_actor(actor: Node2D) -> void:
	unbind_actor()
	if not is_instance_valid(actor) or actor.get("is_locally_controlled") == false or not actor.has_method("get_health_component"): return
	_actor = actor
	player = actor
	_health = actor.get_health_component()
	_health.changed.connect(_on_health_changed)
	_actor.tree_exiting.connect(unbind_actor)
	update_three_bars()
	show()

func unbind_actor() -> void:
	if is_instance_valid(_health) and _health.changed.is_connected(_on_health_changed): _health.changed.disconnect(_on_health_changed)
	if is_instance_valid(_actor) and _actor.tree_exiting.is_connected(unbind_actor): _actor.tree_exiting.disconnect(unbind_actor)
	_health = null
	_actor = null
	hide()

func _on_health_changed(_current: float, _maximum: float) -> void:
	update_three_bars()

func update_three_bars() -> void:
	update_health_cells()

func update_health_cells() -> void:
	if not is_instance_valid(_health): return
	var cell_hp: float = _health.damage_cell_size if _health.damage_cell_size > 0.0 else single_bar_hp
	for index in range(_cells.size()):
		var cell := _cells[index]
		cell.max_value = cell_hp
		cell.value = clampf(_health.current - index * cell_hp, 0.0, cell_hp)
		cell.visible = cell.value > 0.0 and index < ceili(_health.maximum / cell_hp)
