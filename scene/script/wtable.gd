extends Node2D

var win_countdown: bool = false
var wp: Area2D = null


func _on_body_entered(body: AnimatedSprite2D) -> void:
	print("touched")
	wp = body.current_winning_point
	wp.ref = $"."
	
