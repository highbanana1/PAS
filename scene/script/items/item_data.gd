extends RefCounted
## Common consumable contract. Inventory does not branch on item kind.
var kind: StringName = &"item"
var capacity: float = 1.0
var remaining: float = 1.0
var holder: WeakRef
var icon: Texture2D
var icon_region: Rect2
func is_full() -> bool:
	return is_equal_approx(remaining, capacity)
func consume(amount: float) -> float:
	if not is_finite(amount) or amount <= 0.0: return 0.0
	var used := minf(amount, remaining); remaining = maxf(remaining - used, 0.0); return used
func supports_continuous_use() -> bool: return false
func use_once(_actor: Node2D) -> bool: return false
func heal_continuously(_actor: Node2D, _amount: float) -> float: return 0.0
