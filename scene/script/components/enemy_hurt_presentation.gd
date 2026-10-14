class_name EnemyHurtPresentation
extends Node
const Context = preload("res://scene/script/combat/attack_context.gd")
const Feedback = preload("res://scene/script/combat_feedback.gd")
@export var reaction_duration: float = 0.14
var is_playing: bool = false
var _actor: Node2D
var _receiver: Node
var _sprite: AnimatedSprite2D
var _rest_scale: Vector2
var _age: float = 0.0

func configure(actor: Node2D, receiver: Node, sprite: AnimatedSprite2D) -> void:
	if is_instance_valid(_receiver) and _receiver.attack_received.is_connected(_on_attack_received):
		_receiver.attack_received.disconnect(_on_attack_received)
	reset_state()
	_actor = actor
	_receiver = receiver
	_sprite = sprite
	_rest_scale = sprite.scale
	_receiver.attack_received.connect(_on_attack_received)

func _on_attack_received(_context: RefCounted, result: int) -> void:
	if result != Context.Result.DAMAGED and result != Context.Result.KILLED: return
	if not is_instance_valid(_actor) or not is_instance_valid(_sprite): return
	is_playing = true
	_age = 0.0
	_sprite.scale = _rest_scale * Vector2(1.12, 0.88)
	Feedback.spawn_hit(_actor, _actor.global_position, _sprite)

func _process(delta: float) -> void:
	if not is_playing: return
	_age += delta
	if not is_instance_valid(_sprite) or _age >= reaction_duration:
		reset_state()
		return
	var strength := pow(1.0 - _age / maxf(reaction_duration, 0.001), 2.0)
	_sprite.scale = _rest_scale * Vector2(1.0 + 0.12 * strength, 1.0 - 0.12 * strength)

func reset_state() -> void:
	if is_playing and is_instance_valid(_sprite): _sprite.scale = _rest_scale
	is_playing = false

func _exit_tree() -> void:
	reset_state()
