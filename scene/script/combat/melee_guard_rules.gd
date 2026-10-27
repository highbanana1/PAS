class_name MeleeGuardRules
extends Resource
## One Inspector-editable source of truth for offline sword/guard behavior and
## the host-authoritative match snapshot. Only to_authority_config() crosses
## the seam; clients never submit or mutate these values.

const DEFAULT_SWORD_DAMAGE: float = 2.0
const DEFAULT_SWORD_RANGE: float = 36.0
const DEFAULT_SWORD_ARC: float = 120.0
const DEFAULT_SWORD_WINDUP: float = 0.045
const DEFAULT_SWORD_SWING: float = 0.09
const DEFAULT_SWORD_RECOVERY: float = 0.11
const DEFAULT_SWORD_COOLDOWN: float = 0.245
const DEFAULT_GUARD_MAXIMUM: float = 100.0
const DEFAULT_GUARD_BLOCK_COST: float = 20.0
const DEFAULT_GUARD_DRAIN: float = 10.0
const DEFAULT_GUARD_RECOVERY: float = 15.0
const DEFAULT_GUARD_ARC: float = 140.0

@export_group("Sword")
@export_range(0.1, 100.0, 0.1) var sword_damage: float = DEFAULT_SWORD_DAMAGE
@export_range(1.0, 512.0, 1.0, "suffix:px") var sword_range: float = DEFAULT_SWORD_RANGE
@export_range(10.0, 170.0, 1.0, "suffix:°") var sword_arc: float = DEFAULT_SWORD_ARC
@export_range(0.001, 2.0, 0.001, "suffix:s") var sword_windup: float = DEFAULT_SWORD_WINDUP
@export_range(0.001, 2.0, 0.001, "suffix:s") var sword_swing: float = DEFAULT_SWORD_SWING
@export_range(0.001, 2.0, 0.001, "suffix:s") var sword_recovery: float = DEFAULT_SWORD_RECOVERY
@export_range(0.001, 3.0, 0.001, "suffix:s") var sword_cooldown: float = DEFAULT_SWORD_COOLDOWN

@export_group("Guard")
@export_range(1.0, 1000.0, 1.0) var guard_maximum: float = DEFAULT_GUARD_MAXIMUM
@export_range(0.1, 1000.0, 0.1) var guard_block_cost: float = DEFAULT_GUARD_BLOCK_COST
@export_range(0.1, 120.0, 0.1, "suffix:s") var guard_drain_duration: float = DEFAULT_GUARD_DRAIN
@export_range(0.1, 120.0, 0.1, "suffix:s") var guard_recovery_duration: float = DEFAULT_GUARD_RECOVERY
@export_range(10.0, 180.0, 1.0, "suffix:°") var guard_arc: float = DEFAULT_GUARD_ARC

func to_authority_config() -> Dictionary:
	return {
		"sword": {
			"damage": _bounded(sword_damage, DEFAULT_SWORD_DAMAGE, 0.1, 100.0),
			"range": _bounded(sword_range, DEFAULT_SWORD_RANGE, 1.0, 512.0),
			"arc": _bounded(sword_arc, DEFAULT_SWORD_ARC, 10.0, 170.0),
			"windup": _bounded(sword_windup, DEFAULT_SWORD_WINDUP, 0.001, 2.0),
			"swing": _bounded(sword_swing, DEFAULT_SWORD_SWING, 0.001, 2.0),
			"recovery": _bounded(sword_recovery, DEFAULT_SWORD_RECOVERY, 0.001, 2.0),
			"cooldown": _bounded(sword_cooldown, DEFAULT_SWORD_COOLDOWN, 0.001, 3.0),
		},
		"guard": {
			"maximum": _bounded(guard_maximum, DEFAULT_GUARD_MAXIMUM, 1.0, 1000.0),
			"block_cost": _bounded(guard_block_cost, DEFAULT_GUARD_BLOCK_COST, 0.1, 1000.0),
			"duration": _bounded(guard_drain_duration, DEFAULT_GUARD_DRAIN, 0.1, 120.0),
			"recovery_duration": _bounded(guard_recovery_duration, DEFAULT_GUARD_RECOVERY, 0.1, 120.0),
			"angle": _bounded(guard_arc, DEFAULT_GUARD_ARC, 10.0, 180.0),
		},
	}

## Host-side programmatic registration uses the same validation as Inspector.
static func validated_config(candidate: Dictionary) -> Dictionary:
	var rules = load("res://scene/script/combat/melee_guard_rules.gd").new()
	var properties := {
		"sword": {"damage": "sword_damage", "range": "sword_range", "arc": "sword_arc",
			"windup": "sword_windup", "swing": "sword_swing",
			"recovery": "sword_recovery", "cooldown": "sword_cooldown"},
		"guard": {"maximum": "guard_maximum", "block_cost": "guard_block_cost",
			"duration": "guard_drain_duration", "recovery_duration": "guard_recovery_duration",
			"angle": "guard_arc"},
	}
	for section: String in properties:
		var supplied: Variant = candidate.get(section, {})
		if not supplied is Dictionary:
			continue
		for key: String in properties[section]:
			var value: Variant = supplied.get(key)
			if value is float or value is int:
				rules.set(properties[section][key], float(value))
	return rules.to_authority_config()

static func _bounded(value: float, fallback: float, minimum: float, maximum: float) -> float:
	return value if is_finite(value) and value >= minimum and value <= maximum else fallback
