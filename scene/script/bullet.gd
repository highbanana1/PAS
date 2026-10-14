extends Node2D

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
	if body.has_method("receive_attack"):
		# Use the incoming travel direction, not the shooter's current position.
		var attack_origin := global_position - global_transform.x.normalized() * 64.0
		body.receive_attack(damage, attack_origin, true)
	elif body.is_in_group("enemy"):
		body.get_hited = true
		body.hurt(damage)
	queue_free()
func die()->void:
	queue_free()
