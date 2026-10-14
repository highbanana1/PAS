extends Node2D
const Context = preload("res://scene/script/combat/attack_context.gd")
const Receiver = preload("res://scene/script/combat/combat_receiver.gd")

const SPEED= 700
var shooter: Node2D = null
@export var damage: int = 1

# Called when the node enters the scene tree for the first time.
func _ready() -> void:
	pass # Replace with function body.


# Called every frame. 'delta' is the elapsed time since the previous frame.
func _process(delta: float) -> void:
	position += transform.x * SPEED * delta
	


func _on_visible_on_screen_notifier_2d_screen_exited() -> void:
	queue_free()


func _on_area_2d_area_entered(area: Area2D) -> void:
	pass


func _on_area_2d_body_entered(body: Node2D) -> void:
	if is_queued_for_deletion():
		return
	if is_instance_valid(shooter) and body == shooter:
		return
	# Capture incoming direction, independent of the shooter's later position.
	var attack_origin := global_position - global_transform.x.normalized() * 64.0
	Receiver.deliver(body, Context.new(damage, attack_origin, shooter, true))
	queue_free()
func die()->void:
	queue_free()
