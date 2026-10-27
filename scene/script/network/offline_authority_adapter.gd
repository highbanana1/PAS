class_name OfflineAuthorityAdapter
extends Node

## Offline bridge between existing local input and MatchAuthority. It samples
## keyboard input only for actors explicitly bound as local, submits bound
## commands, advances the authority on a fixed cadence, and mirrors snapshots
## back onto the scene nodes. It never writes health or authoritative position.

const MatchAuthorityScript = preload("res://scene/script/network/match_authority.gd")

var authority
var _bindings: Dictionary = {}
var _actor_ids: Dictionary = {}
var _accumulator: float = 0.0
var _next_id: int = 0

func _ready() -> void:
	if authority == null:
		authority = MatchAuthorityScript.new()

func bind_actor(actor: Node, player_id: StringName = &"") -> StringName:
	if not is_instance_valid(actor):
		return &""
	if authority == null:
		authority = MatchAuthorityScript.new()
	if _actor_ids.has(actor.get_instance_id()):
		return _actor_ids[actor.get_instance_id()]
	var bound_id := player_id
	if bound_id == &"":
		_next_id += 1
		bound_id = StringName("player_%d" % _next_id)
	if not authority.register_player(bound_id, actor):
		return &""
	_bindings[bound_id] = actor
	_actor_ids[actor.get_instance_id()] = bound_id
	return bound_id

func unbind_actor(actor: Node) -> bool:
	if not is_instance_valid(actor):
		return false
	var instance_id := actor.get_instance_id()
	if not _actor_ids.has(instance_id):
		return false
	var bound_id: StringName = _actor_ids[instance_id]
	_actor_ids.erase(instance_id)
	_bindings.erase(bound_id)
	if authority != null:
		authority.unregister_player(bound_id)
	return true

func _physics_process(delta: float) -> void:
	if authority == null:
		return
	_submit_local_input()
	_accumulator += maxf(delta, 0.0)
	while _accumulator >= MatchAuthorityScript.FIXED_STEP:
		authority.step()
		_accumulator -= MatchAuthorityScript.FIXED_STEP
	_apply_snapshots()

func _submit_local_input() -> void:
	for player_id: StringName in _bindings.keys():
		var actor: Node = _bindings[player_id]
		if not is_instance_valid(actor):
			continue
		if actor.get("is_dead") == true or actor.get("is_locally_controlled") != true:
			continue
		var direction := Vector2(
			Input.get_axis("left", "right"),
			Input.get_axis("up", "down")
		)
		authority.submit_command(player_id, {"type": &"move", "direction": direction})
		if Input.is_action_just_pressed("jump"):
			authority.submit_command(player_id, {"type": &"jump"})
		if Input.is_action_just_pressed("dash"):
			authority.submit_command(player_id, {"type": &"dash", "direction": direction})

func _apply_snapshots() -> void:
	for player_id: StringName in _bindings.keys():
		var actor: Node = _bindings[player_id]
		if not is_instance_valid(actor):
			continue
		var snapshot: Dictionary = authority.get_snapshot(player_id)
		if snapshot.is_empty():
			continue
		if actor is Node2D:
			(actor as Node2D).global_position = snapshot["position"]
		if actor is CharacterBody2D:
			(actor as CharacterBody2D).velocity = snapshot["velocity"]
