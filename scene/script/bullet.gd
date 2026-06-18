extends Node2D

const SPEED= 700

# Called when the node enters the scene tree for the first time.
func _ready() -> void:
	pass # Replace with function body.


# Called every frame. 'delta' is the elapsed time since the previous frame.
func _process(delta: float) -> void:
	position += transform.x * SPEED * delta
	


func _on_visible_on_screen_notifier_2d_screen_exited() -> void:
	queue_free()


func _on_area_2d_area_entered(area: Area2D) -> void:
	#if area.is_in_group("enemy"):
	#	area.get_hit =true
	#	queue_free()
	pass


func _on_area_2d_body_entered(body: Node2D) -> void:
	#if body.is_in_group("enemy"):
	#	body.get_hit =true
	#	queue_free()
	pass
func die()->void:
	queue_free()
