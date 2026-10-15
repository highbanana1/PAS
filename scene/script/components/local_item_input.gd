extends Node
## Local key timing only; inventory and healing commands remain independently callable.
var actor: Node2D
var items: Node
@export_range(0.1, 2.0, 0.05) var hold_threshold: float = 0.3
var held: bool = false
var _elapsed: float = 0.0
func configure(owner_actor: Node2D, inventory: Node) -> void:
	actor = owner_actor; items = inventory
	actor.character_died.connect(reset_state)
	actor.respawned.connect(reset_state)
	actor.get_weapon_controller().weapon_changed.connect(_on_weapon_changed)
func enabled() -> bool:
	return is_instance_valid(actor) and actor.get("is_dead") != true and actor.get("is_locally_controlled") == true
func reset_state() -> void:
	held = false; _elapsed = 0.0
	if is_instance_valid(items): items.cancel_use()
func _on_weapon_changed(_id: int) -> void:
	reset_state(); items.deselect_item()
func _is_weapon_event(event: InputEvent) -> bool:
	return event.is_action_pressed("weapon_slot_1") or event.is_action_pressed("weapon_slot_2") or event.is_action_pressed("weapon_next") or event.is_action_pressed("weapon_previous")
func _input(event: InputEvent) -> void:
	if enabled() and _is_weapon_event(event): _on_weapon_changed(0)
func _unhandled_input(event: InputEvent) -> void:
	if handle_event(event): get_viewport().set_input_as_handled()
func handle_event(event: InputEvent) -> bool:
	if not enabled(): return false
	if event is InputEventKey and event.echo: return false
	if _is_weapon_event(event): _on_weapon_changed(0); return false
	if event.is_action_pressed("item_select_1"):
		items.select_item()
		if not held: held = true; _elapsed = 0.0
		return true
	if event.is_action_released("item_select_1"):
		reset_state(); return true
	if event.is_action_pressed("item_use") and items.selected:
		items.use_selected(); return true
	if event.is_action_pressed("item_pickup"):
		items.pick_up_nearest(); return true
	return false
func _process(delta: float) -> void:
	tick(delta)
func tick(delta: float) -> void:
	if not enabled(): reset_state(); return
	if not held or not is_finite(delta) or delta <= 0.0: return
	var previous := _elapsed; _elapsed += delta
	var active_time := maxf(_elapsed - hold_threshold, 0.0) - maxf(previous - hold_threshold, 0.0)
	if active_time > 0.0:
		items.begin_continuous_use(); items.tick_continuous_use(active_time)
