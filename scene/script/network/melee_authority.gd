extends RefCounted
## Host-only sword rule module. It validates action identity, alive life, aim,
## cooldown, range, arc and world line of sight. Damage is delivered by a short
## host-clocked angular sweep; each target life can be hit at most once per
## action. Damage/target/life values supplied by a client are ignored.

const Receiver = preload("res://scene/script/combat/combat_receiver.gd")
const Context = preload("res://scene/script/combat/attack_context.gd")
const Rules = preload("res://scene/script/combat/melee_guard_rules.gd")

const FIXED_STEP: float = 1.0 / 60.0
## Small angular overlap, mirroring the offline sector, so a target on a sector
## boundary is not missed by floating point. It never widens the nominal arc.
const SECTOR_PADDING_DEGREES: float = 5.0
const MAX_EVENTS: int = 128

var _pending: Array[Dictionary] = []
var _next_sword_tick: Dictionary = {}
var _busy_until_tick: Dictionary = {}
var _used_actions: Dictionary = {}
var _events: Array[Dictionary] = []
var _event_id: int = 0
var _tick: int = 0
var _player_rules: Dictionary = {}

func configure_player(player_id: StringName, rules: Dictionary) -> void:
	_player_rules[player_id] = (rules if not rules.is_empty() else _default_rules()).duplicate(true)

func remove_player(player_id: StringName) -> void:
	_player_rules.erase(player_id)
	_next_sword_tick.erase(player_id)
	_busy_until_tick.erase(player_id)
	var kept: Array[Dictionary] = []
	for action: Dictionary in _pending:
		if StringName(action.player_id) != player_id:
			kept.append(action)
	_pending = kept

func request_sword(player_id: StringName, actor: Node, direction: Variant, action_id: int,
		tick: int, life_id: int, guard) -> bool:
	if not is_instance_valid(actor) or not actor is Node2D:
		return false
	if actor.get("is_dead") == true:
		return false
	if action_id <= 0:
		return false
	if not direction is Vector2 or not (direction as Vector2).is_finite():
		return false
	var aim: Vector2 = direction
	# A finite but huge vector can overflow length_squared to infinity. Reject
	# it before normalizing, matching the authoritative shotgun validation.
	var aim_length_squared: float = aim.length_squared()
	if not is_finite(aim_length_squared) or aim_length_squared < 0.000001:
		return false
	if tick < int(_next_sword_tick.get(player_id, -1)):
		return false
	var key := "%s:%d" % [String(player_id), action_id]
	if _used_actions.has(key):
		return false
	var rules: Dictionary = _rules_for(player_id)
	var windup_ticks := _duration_ticks(float(rules.get("windup", Rules.DEFAULT_SWORD_WINDUP)))
	var sweep_ticks := _duration_ticks(float(rules.get("swing", Rules.DEFAULT_SWORD_SWING)))
	var cooldown_ticks := _duration_ticks(float(rules.get("cooldown", Rules.DEFAULT_SWORD_COOLDOWN)))
	var full_action_seconds := float(rules.get("windup", Rules.DEFAULT_SWORD_WINDUP)) \
		+ float(rules.get("swing", Rules.DEFAULT_SWORD_SWING)) \
		+ float(rules.get("recovery", Rules.DEFAULT_SWORD_RECOVERY))
	cooldown_ticks = maxi(cooldown_ticks, _duration_ticks(full_action_seconds))
	_used_actions[key] = tick
	_next_sword_tick[player_id] = tick + cooldown_ticks
	_busy_until_tick[player_id] = tick + _duration_ticks(full_action_seconds)
	if guard != null:
		guard.cancel()
	_pending.append({
		"player_id": String(player_id),
		"actor": actor,
		"direction": aim.normalized(),
		"action_id": action_id,
		"attacker_life_id": life_id,
		"request_tick": tick,
		"resolve_tick": tick + windup_ticks,
		"damage": float(rules.get("damage", Rules.DEFAULT_SWORD_DAMAGE)),
		"range": float(rules.get("range", Rules.DEFAULT_SWORD_RANGE)),
		"arc": float(rules.get("arc", Rules.DEFAULT_SWORD_ARC)),
		"sweep_ticks": sweep_ticks,
		"sweep_step": 0,
		"hits": {},
	})
	_emit({
		"type": "sword_started",
		"action_id": action_id,
		"attacker_id": String(player_id),
		"attacker_life_id": life_id,
		"direction": aim.normalized(),
		"damage": float(rules.get("damage", Rules.DEFAULT_SWORD_DAMAGE)),
		"range": float(rules.get("range", Rules.DEFAULT_SWORD_RANGE)),
		"arc": float(rules.get("arc", Rules.DEFAULT_SWORD_ARC)),
	})
	return true

func step(tick: int, players: Dictionary) -> void:
	_tick = tick
	for index in range(_pending.size() - 1, -1, -1):
		var action: Dictionary = _pending[index]
		if tick < int(action.resolve_tick):
			continue
		var attacker := _action_attacker(action, players)
		if not is_instance_valid(attacker):
			_pending.remove_at(index)
			_emit({"type": "sword_cancelled", "action_id": action.action_id,
				"attacker_id": String(action.player_id),
				"attacker_life_id": int(action.attacker_life_id),
				"reason": "attacker_life_changed"})
			continue
		var sweep_step: int = int(action.sweep_step)
		var sweep_ticks := maxi(int(action.get("sweep_ticks", 1)), 1)
		var previous := _sweep_progress(float(sweep_step) / float(sweep_ticks))
		var current := _sweep_progress(float(sweep_step + 1) / float(sweep_ticks))
		_sweep_sector(action, attacker, players, previous, current)
		sweep_step += 1
		action["sweep_step"] = sweep_step
		if sweep_step >= sweep_ticks:
			_pending.remove_at(index)
			if (action.hits as Dictionary).is_empty():
				_emit({"type": "sword_miss", "action_id": action.action_id,
					"attacker_id": String(action.player_id),
					"attacker_life_id": int(action.attacker_life_id)})

func get_state() -> Dictionary:
	return {
		"revision": _event_id,
		"server_tick": _tick,
		"pending_actions": _pending.size(),
		"events": _events.duplicate(true),
	}

## Mirrors the offline WeaponController rule: a swing (including its recovery
## window) cannot be interrupted by held guard input.
func is_busy(player_id: StringName, tick: int) -> bool:
	return tick < int(_busy_until_tick.get(player_id, -1))

func reset_player(player_id: StringName, next_life: int) -> void:
	_next_sword_tick.erase(player_id)
	_busy_until_tick.erase(player_id)
	var kept: Array[Dictionary] = []
	for action: Dictionary in _pending:
		if StringName(action.player_id) != player_id:
			kept.append(action)
	_pending = kept
	_emit({
		"type": "sword_reset",
		"attacker_id": String(player_id),
		"attacker_life_id": next_life,
	})

func _rules_for(player_id: StringName) -> Dictionary:
	var rules_variant: Variant = _player_rules.get(player_id, {})
	return rules_variant if rules_variant is Dictionary and not rules_variant.is_empty() else _default_rules()

func _default_rules() -> Dictionary:
	return Rules.new().to_authority_config().sword

func _duration_ticks(seconds: float) -> int:
	return maxi(int(ceil(seconds / FIXED_STEP)), 1)

func _action_attacker(action: Dictionary, players: Dictionary) -> Node2D:
	var attacker_record: Dictionary = players.get(StringName(action.player_id), {})
	var attacker: Node2D = attacker_record.get("actor")
	if not is_instance_valid(attacker) or attacker.get("is_dead") == true \
			or bool(attacker_record.get("dead", false)) \
			or int(attacker_record.get("life_id", -1)) != int(action.attacker_life_id):
		return null
	return attacker

## Same eased travel as the offline sword, sampled once per fixed authority tick.
func _sweep_progress(progress: float) -> float:
	return 1.0 - pow(1.0 - progress, 2.0)

func _sweep_sector(action: Dictionary, attacker: Node2D, players: Dictionary,
		previous: float, current: float) -> void:
	var attacker_id := String(action.player_id)
	var life_id := int(action.attacker_life_id)
	var damage := float(action.get("damage", Rules.DEFAULT_SWORD_DAMAGE))
	var attack_range := float(action.get("range", Rules.DEFAULT_SWORD_RANGE))
	var swing_angle := float(action.get("arc", Rules.DEFAULT_SWORD_ARC))
	var half_angle := deg_to_rad(swing_angle * 0.5)
	var padding := deg_to_rad(SECTOR_PADDING_DEGREES)
	# The blade moves from -half_angle to +half_angle. Only this interval's
	# sector is queried, so a side target waits until the blade reaches it.
	var sector_start := maxf(lerpf(-half_angle, half_angle, previous) - padding, -half_angle)
	var sector_finish := minf(lerpf(-half_angle, half_angle, current) + padding, half_angle)
	var targets := _targets(
		attacker, action.direction, players, attacker_id, sector_start, sector_finish, attack_range)
	var hits: Dictionary = action.hits
	for target_record: Dictionary in targets:
		var target_actor: Node2D = target_record.get("actor")
		var target_id := String(target_record.get("id", ""))
		var target_life := int(target_record.get("life_id", -1))
		if target_life <= 0 or not is_instance_valid(target_actor) or target_actor.get("is_dead") == true:
			continue
		var hit_key := _hit_key(action, target_id, target_life)
		if hits.has(hit_key):
			continue
		hits[hit_key] = true
		var origin: Vector2 = attacker.global_position
		var toward_attack: Vector2 = origin - target_actor.global_position
		var guard_state = target_record.get("guard")
		var blocked := false
		if guard_state != null:
			var block: Dictionary = guard_state.try_block(toward_attack, true)
			if bool(block.get("blocked", false)):
				blocked = true
				_emit({
					"type": "sword_hit",
					"action_id": int(action.action_id),
					"attacker_id": attacker_id,
					"attacker_life_id": life_id,
					"target_id": target_id,
					"target_life_id": target_life,
					"damage": damage,
					"result": Context.Result.BLOCKED,
					"guard": block,
				})
		if blocked:
			continue
		# The guard decision was made above against host state. Passing an
		# unblockable context here prevents the target's local component from
		# charging or deciding a second time.
		var result: int = Receiver.deliver(target_actor, Context.new(damage, origin, attacker, false))
		_emit({
			"type": "sword_hit",
			"action_id": int(action.action_id),
			"attacker_id": attacker_id,
			"attacker_life_id": life_id,
			"target_id": target_id,
			"target_life_id": target_life,
			"damage": damage,
			"result": result,
		})

func _hit_key(action: Dictionary, target_id: String, target_life: int) -> String:
	return "%s:%d:%d:%s:%d" % [
		String(action.player_id), int(action.attacker_life_id),
		int(action.action_id), target_id, target_life,
	]

func _targets(attacker: Node2D, direction: Vector2, players: Dictionary, attacker_id: String,
		sector_start: float, sector_finish: float, attack_range: float) -> Array[Dictionary]:
	var candidates: Array[Dictionary] = []
	for player_id: StringName in players:
		var record: Dictionary = players[player_id]
		if String(player_id) == attacker_id:
			continue
		var actor: Node2D = record.get("actor")
		if not is_instance_valid(actor) or actor.get("is_dead") == true \
				or bool(record.get("dead", false)) or bool(record.get("extracted", false)):
			continue
		if int(record.get("life_id", 0)) <= 0:
			continue
		var offset: Vector2 = actor.global_position - attacker.global_position
		var distance := offset.length()
		if distance <= 0.0 or distance > attack_range:
			continue
		var target_angle := direction.angle_to(offset)
		if target_angle < sector_start or target_angle > sector_finish:
			continue
		if not _has_line_of_sight(attacker, actor):
			continue
		candidates.append({"id": String(player_id), "actor": actor,
			"life_id": int(record.get("life_id", 1)), "guard": record.get("guard"),
			"distance": distance})
	candidates.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
		return float(a.distance) < float(b.distance))
	return candidates

func _has_line_of_sight(attacker: Node2D, target: Node2D) -> bool:
	if not attacker.is_inside_tree() or not target.is_inside_tree():
		return true
	var query := PhysicsRayQueryParameters2D.create(attacker.global_position, target.global_position, 1)
	if attacker is CollisionObject2D:
		query.exclude = [attacker.get_rid()]
	return attacker.get_world_2d().direct_space_state.intersect_ray(query).is_empty()

func _emit(event: Dictionary) -> void:
	_event_id += 1
	event["event_id"] = _event_id
	event["server_tick"] = _tick
	_events.append(event)
	if _events.size() > MAX_EVENTS:
		_events.pop_front()
