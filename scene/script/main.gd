extends Node2D

const OfflineAuthority = preload("res://scene/script/network/offline_authority_adapter.gd")

var authority_adapter: Node

func _ready() -> void:
	# The overlay belongs to this viewport's local player, not every player.
	$DeathScreen.bind_actor($CharacterBody2D)
	$CombatHUD.bind_actor($CharacterBody2D)
	# Keep the old direct entry only as the compatibility fallback for actors
	# that are not bound here. The host's local input goes through this queue.
	authority_adapter = OfflineAuthority.new()
	authority_adapter.name = "OfflineAuthority"
	add_child(authority_adapter)
	authority_adapter.bind_actor($CharacterBody2D, &"local")
