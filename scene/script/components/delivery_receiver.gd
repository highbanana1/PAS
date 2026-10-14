class_name DeliveryReceiver
extends Node
signal delivered(item: Area2D)
var actor: Node2D
var item: Area2D

func configure(owner_actor: Node2D) -> void:
	actor = owner_actor

func can_accept(candidate: Area2D) -> bool:
	return is_instance_valid(actor) and not is_instance_valid(item) and is_instance_valid(candidate) and candidate.has_method("get_carryable_component")

func accept(candidate: Area2D) -> bool:
	if not can_accept(candidate): return false
	if not candidate.get_carryable_component().transfer_to(self): return false
	item = candidate
	delivered.emit(item)
	return true
