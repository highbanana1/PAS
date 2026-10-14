extends Area2D

var win_countdown: bool = false
var wp: Area2D = null


func _physics_process(_delta: float) -> void:
	if is_instance_valid(wp):
		return
	# Also accept a star picked up while the player is already touching the table.
	for body in get_overlapping_bodies():
		_on_body_entered(body)
		if is_instance_valid(wp):
			break


func _on_body_entered(body: Node2D) -> void:
	if is_instance_valid(wp) or not body.is_in_group("player"):
		return
	var carried_star: Area2D = body.get("current_winning_point")
	if not is_instance_valid(carried_star):
		return
	if carried_star.has_method("deliver_to") and carried_star.call("deliver_to", self):
		wp = carried_star
