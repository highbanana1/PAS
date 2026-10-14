extends Area2D

@export var float_offset_y: float = -30

var is_picked: bool = false
var ref: Node2D = null
# Former carriers must leave the pickup area after revival before re-entering.
var _released_carriers: Dictionary = {}


func _ready() -> void:
	global_position = Vector2(100, -100)
	body_entered.connect(_on_player_touch)


func _process(_delta: float) -> void:
	if is_picked and is_instance_valid(ref):
		global_position = ref.global_position + Vector2(0, float_offset_y)
		global_position.y += sin(Time.get_ticks_msec() * 0.003) * 2.5


func _physics_process(_delta: float) -> void:
	for carrier_id in _released_carriers.keys():
		var entry: Dictionary = _released_carriers[carrier_id]
		var carrier: Node2D = entry["body"].get_ref() as Node2D
		if not is_instance_valid(carrier):
			_released_carriers.erase(carrier_id)
		elif carrier.get("is_dead") == true:
			entry["settle_frames"] = 2
		elif entry["settle_frames"] > 0:
			# Collision filters and overlap lists update in separate physics steps.
			entry["settle_frames"] -= 1
		elif not overlaps_body(carrier):
			_released_carriers.erase(carrier_id)


func _on_player_touch(body: Node2D) -> void:
	if is_picked or not body.is_in_group("player"):
		return
	if body.get("is_dead") == true:
		return
	if _released_carriers.has(body.get_instance_id()):
		return
	is_picked = true
	ref = body
	body.set("current_winning_point", self)


func drop_from_carrier() -> void:
	if not is_picked or not is_instance_valid(ref) or not ref.is_in_group("player"):
		return
	global_position = ref.global_position
	_released_carriers[ref.get_instance_id()] = {"body": weakref(ref), "settle_frames": 2}
	ref.set("current_winning_point", null)
	ref = null
	is_picked = false


func deliver_to(table: Area2D) -> bool:
	if not is_picked or not is_instance_valid(ref):
		return false
	if not table.is_in_group("table") or not ref.is_in_group("player"):
		return false
	if ref.get("current_winning_point") != self:
		return false
	ref.set("current_winning_point", null)
	ref = table
	return true
