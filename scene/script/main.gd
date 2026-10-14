extends Node2D

func _ready() -> void:
	# The overlay belongs to this viewport's local player, not every player.
	$DeathScreen.bind_player($CharacterBody2D)
	$CombatHUD.bind_player($CharacterBody2D)
