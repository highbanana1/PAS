class_name CarryComponent
extends Node
signal item_changed(item: Area2D)
var actor: Node2D
var item: Area2D

func configure(owner_actor: Node2D) -> void:
	actor = owner_actor

func try_pick_up(candidate: Area2D) -> bool:
	if not is_instance_valid(actor) or actor.get("is_dead") == true or is_instance_valid(item): return false
	if not is_instance_valid(candidate) or not candidate.has_method("get_carryable_component"): return false
	var carryable = candidate.get_carryable_component()
	if not carryable.attach_to(actor, self): return false
	item = candidate
	item_changed.emit(item)
	return true

func drop() -> void:
	if is_instance_valid(item): item.get_carryable_component().release()
	clear_item()

func clear_item() -> void:
	item = null
	item_changed.emit(null)

func deliver_to(receiver: Node) -> bool:
	if not is_instance_valid(item) or not is_instance_valid(receiver): return false
	return receiver.accept(item)
