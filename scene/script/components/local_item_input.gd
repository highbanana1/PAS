extends Node
## Local key timing only; inventory and healing commands remain independently callable.
var actor: Node2D
var items: Node
@export_range(0.1, 2.0, 0.05) var hold_threshold: float = 0.3
var held: bool = false
var _elapsed: float = 0.0
var _held_slot: int = -1
var _held_item: RefCounted
func configure(owner_actor: Node2D, inventory: Node) -> void:
	actor = owner_actor; items = inventory
	actor.character_died.connect(reset_state)
	actor.respawned.connect(reset_state)
	actor.get_weapon_controller().weapon_changed.connect(_on_weapon_changed)
func enabled() -> bool:
	return is_instance_valid(actor) and actor.get("is_dead") != true and actor.get("is_locally_controlled") == true
func reset_state() -> void:
	held = false; _elapsed = 0.0; _held_slot = -1; _held_item = null
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
	for slot in range(3):
		var action := "item_select_%d" % (slot + 1)
		if event.is_action_pressed(action):
			if not held or _held_slot != slot:
				reset_state(); items.select_item(slot)
				held = true; _held_slot = slot; _held_item = items.current_item()
			return true
		if event.is_action_released(action) and _held_slot == slot:
			reset_state(); return true
	if event.is_action_pressed("item_use") and items.selected:
		if items.use_selected(): reset_state()
		return true
	if event.is_action_pressed("item_pickup"):
		items.pick_up_nearest(); return true
	return false
func _process(delta: float) -> void:
	tick(delta)
func tick(delta: float) -> void:
	if not enabled(): reset_state(); return
	if not held or not is_finite(delta) or delta <= 0.0: return
	if items.current_item() != _held_item or items.selected_index != _held_slot:
		reset_state(); return
	var previous := _elapsed; _elapsed += delta
	var active_time := maxf(_elapsed - hold_threshold, 0.0) - maxf(previous - hold_threshold, 0.0)
	if active_time > 0.0:
		items.begin_continuous_use(); items.tick_continuous_use(active_time)
