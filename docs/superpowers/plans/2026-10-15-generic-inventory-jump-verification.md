# Generic inventory and one-time jump verification

User requirements: jumpitem image, one-time extra airborne jump, generic inventory assigned by pickup order. 3/4/5 select slot positions; E uses current item; F picks nearest eligible item; removal compacts entries; death drops unused items. Health item semantics preserved.

Implementation: ItemData polymorphic contract, InventoryComponent, common ItemPickup, HealthItemData and JumpItemData; old health component and scene paths remain compatibility adapters. CharacterMotor holds a single nonstacking temporary air-jump token, consumed only on an airborne jump after ordinary jumps are exhausted, cleared on reset/death. Independent jump scene can be placed in a level; no additional automatic spawn/drop policy was requested.

RED observed for missing generic inventory interface. New integration tests then GREEN. Fresh final suite: 21 scripts, 292 passing assertions, all process exits0 and stderr empty. Editor recovery-mode import exit0/stderr empty. Real-render screenshots at 640x360 and1152x648 under C:/Users/28478/Documents/Codex/2026-10-15/PAS-jump-item/; mixed and consumed layouts inspected.

Independent gpt-6-astra review found one P2: held slot input could consume a different item after removal. Two regression assertions observed RED; fixed by binding hold to original item identity and clearing hold after successful instant use; full suite GREEN afterward. No other actionable issues reported.

User scenes preserved exactly: enemy.tscn SHA256 ED0F900CF39F340EB5AC60D23A33311327E96CBF94FE6583163F1F0AE40CE3F0; maincharac.tscn SHA256 B62B35939C3C4D9193298A945055B65407D61534D6317315A593FF92FB4C909A. Neither staged.

Protected master5234fb23df615b72d12b0021d4868b155f56436e and develop8b815675428a3251812ef53c32fd12c677fb9dc0 unchanged. Work stays on refactor/reusable-components, no push/merge. Prior approved transparent depleted health-bar visual included in checkpoint.
