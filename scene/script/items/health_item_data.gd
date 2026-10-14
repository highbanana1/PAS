extends RefCounted
## One inventory entry owns one reserve; separate entries never merge charge.
var capacity: float
var remaining: float
var holder: WeakRef
func _init(amount: float = 30.0) -> void:
	capacity = amount if is_finite(amount) and amount > 0.0 else 30.0
	remaining = capacity
func is_full() -> bool:
	return is_equal_approx(remaining, capacity)
func consume(amount: float) -> float:
	if not is_finite(amount) or amount <= 0.0: return 0.0
	var used := minf(amount, remaining)
	remaining = maxf(remaining - used, 0.0)
	return used
