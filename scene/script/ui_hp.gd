extends CanvasLayer
@export var bar1: TextureProgressBar
@export var bar2: TextureProgressBar
@export var bar3: TextureProgressBar
@export var single_bar_hp: float = 30.0
@export var player: Node2D
var _health: Node
var _actor: Node2D

func _ready() -> void:
	bar1.max_value = single_bar_hp
	bar2.max_value = single_bar_hp
	bar3.max_value = single_bar_hp
	bind_actor(player)

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
	if not is_instance_valid(_health): return
	var value: float = clampf(_health.current, 0.0, single_bar_hp * 3.0)
	bar1.value = clampf(value, 0.0, single_bar_hp)
	bar2.value = clampf(value - single_bar_hp, 0.0, single_bar_hp)
	bar3.value = clampf(value - single_bar_hp * 2.0, 0.0, single_bar_hp)
