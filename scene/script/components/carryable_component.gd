class_name CarryableComponent
extends Node
var item: Area2D
var holder: Node2D
var carrier: Node
var delivered: bool = false
var offset_y: float = -30.0
var _released_carriers: Dictionary = {}

func configure(owner_item: Area2D, float_offset: float) -> void:
	item = owner_item
	offset_y = float_offset

func can_pick_up(actor: Node2D) -> bool:
	return is_instance_valid(item) and is_instance_valid(actor) and not is_instance_valid(holder) and not delivered and actor.get("is_dead") != true and not _released_carriers.has(actor.get_instance_id())

func attach_to(actor: Node2D, carry_component: Node) -> bool:
	if not can_pick_up(actor): return false
	holder = actor
	carrier = carry_component
	return true

func release() -> void:
	if delivered: return
	if is_instance_valid(holder):
		item.global_position = holder.global_position
		_released_carriers[holder.get_instance_id()] = {"body": weakref(holder), "settle_frames": 2}
	if is_instance_valid(carrier): carrier.clear_item()
	holder = null
	carrier = null

func transfer_to(receiver: Node) -> bool:
	if delivered or not is_instance_valid(holder) or not is_instance_valid(carrier): return false
	if not is_instance_valid(receiver) or not receiver.can_accept(item): return false
	carrier.clear_item()
	carrier = null
	holder = receiver.actor
	delivered = true
	return true

func follow() -> void:
	if not is_instance_valid(item): return
	if is_instance_valid(holder):
		item.global_position = holder.global_position + Vector2(0, offset_y)
		item.global_position.y += sin(Time.get_ticks_msec() * 0.003) * 2.5
	elif not delivered:
		holder = null
		carrier = null

func settle_pickup() -> void:
	if not is_instance_valid(item): return
	for carrier_id in _released_carriers.keys():
		var entry: Dictionary = _released_carriers[carrier_id]
		var body: Node2D = entry["body"].get_ref() as Node2D
		if not is_instance_valid(body):
			_released_carriers.erase(carrier_id)
		elif body.get("is_dead") == true:
			entry["settle_frames"] = 2
		elif entry["settle_frames"] > 0:
			entry["settle_frames"] -= 1
		elif not item.overlaps_body(body):
			_released_carriers.erase(carrier_id)
