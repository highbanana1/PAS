class_name HealthComponent
extends Node

signal changed(current: float, maximum: float)
signal depleted()
var maximum: float = 90.0
var current: float = 90.0
## Zero keeps ordinary health; positive values absorb damage beyond the active cell.
var damage_cell_size: float = 0.0

func configure(maximum_health: float) -> void:
	assert(is_finite(maximum_health) and maximum_health > 0.0, "Health maximum must be finite and positive")
	maximum = maximum_health
	current = maximum

func set_maximum(value: float) -> void:
	if not is_finite(value) or value <= 0.0: return
	maximum = value
	set_current(current)

func set_current(value: float) -> void:
	if not is_finite(value): return
	var was_alive := current > 0.0
	current = clampf(value, 0.0, maximum)
	changed.emit(current, maximum)
	if was_alive and current <= 0.0: depleted.emit()

func apply_damage(amount: float) -> float:
	if not is_finite(amount) or amount <= 0.0 or current <= 0.0: return 0.0
	var before := current
	if is_finite(damage_cell_size) and damage_cell_size > 0.0:
		var remaining := fposmod(current, damage_cell_size)
		if is_zero_approx(remaining): remaining = damage_cell_size
		amount = minf(amount, remaining)
	set_current(current - amount)
	return before - current

func heal(amount: float) -> float:
	if not is_finite(amount) or amount <= 0.0 or current <= 0.0: return 0.0
	var before := current
	set_current(current + amount)
	return current - before

func restore_full() -> void:
	set_current(maximum)
