# PAS Reusable Gameplay Components Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox syntax for tracking.

**Goal:** 将当前 PAS 游戏代码拆为可复用组件与统一接口，保留现有玩法和效果，为未来联机留出独立命令入口。

**Architecture:** 角色入口组装独立 Node 组件，并把本地 Input 翻译为命令。组件通过显式引用、值对象和信号协作，不依赖 Player 类型、固定父节点名或全局状态。旧属性/函数使用访问器与转发兼容，组件是状态唯一来源。

**Tech Stack:** Godot 4.7.2 / typed GDScript / Node、Node2D、RefCounted / 现有 SceneTree 回归测试。

**Spec:** `docs/superpowers/specs/2026-10-14-reusable-components-design.md`

## Global Constraints

- 基线：develop / 8b815675428a3251812ef53c32fd12c677fb9dc0；在 refactor/reusable-components 工作，develop 不变。
- 不新增实际网络同步、RPC、连击或数值平衡；不修改第三方插件、图片和字体。
- 剑伤害 2 / 范围 36 / 扇形 120 度 / 蓄势 0.045 秒 / 扫过 0.09 秒 / 收剑 0.11 秒。
- 子弹伤害 1 / 速度 700；固体碰撞消失，忽略发射者，命中只结算一次。
- 格挡角度 140 度 / 上限 100 / 防守 10 秒耗尽 / 恢复 15 秒回满 / 每次成功格挡额外扣 20。
- 碰撞伤害不可格挡；空条持续按右键不恢复，松开可恢复；挥剑或持枪但不防守时可恢复。
- 玩家生命 90 / 独立复活默认 5 秒；不暂停世界，保留身份和摄像机；死亡星星无重力掉落。
- 当前移动、跳跃、冲刺、界面布局、像素字体、刀光、命中闪光和格挡火花保持原样。
- 每任务先新增失败测试，验证缺失行为，再实现、全量测试和独立提交。

## Review Focus

1. 组件挂在不同节点名/父节点下：明确 configure 后仍可运行，不偷偷寻找 Player 或固定兄弟。
2. 多角色并存：伤害、蓝条、携带物、倒计时各自隔离；非本地角色不读取本地 Input。
3. 死亡与帧边界同时命中：致死只处理一次，攻击取消，已排队物理事件不重启复活。
4. UI 更换绑定对象/目标删除：旧信号解绑，初值立即刷新，旧对象不再影响新界面。
5. 渲染帧率与物理帧率不同：只更新一套时钟，剑的伤害区间与表现一致，蓝条保持 10/15 秒规则。

## Shared Verification

实际执行统一使用：
`godot.windows.opt.tools.64.exe --headless --path D:/develop/godot/new-game-project --script res://tests/<test>.gd`

Windows 通过隐藏的 Start-Process 等待真实退出，分别保存 stdout/stderr。每个测试必须 exit=0、末行 RESULT: 0 failures、stderr 无脚本错误；缺少 RESULT 不能当成功。每任务跑 tests/test_*.gd 全部测试，基线至少 118 项断言。
变更完成后另跑 `--headless --editor --recovery-mode --path <project> --import`，以及 Compatibility 渲染下的实际画面检查。

### Task 1: 生命组件与统一受击

**Files:** Create `scene/script/components/health_component.gd`, `scene/script/combat/attack_context.gd`, `scene/script/combat/combat_receiver.gd`; Modify `maincharac.gd`, `enemy.gd`, `bullet.gd`, `sword.gd` and player/enemy scenes; Test `tests/test_combat_components.gd`。

**Interfaces:** HealthComponent.apply_damage(amount: float) -> float、heal(amount: float) -> float、restore_full() -> void，changed(current, maximum)、depleted。AttackContext.new(amount, origin, source, blockable)，AttackResult={IGNORED,BLOCKED,DAMAGED,KILLED}。CombatReceiver.configure(actor, health, guard=null) -> void、receive_attack(context) -> int。

- [ ] Write failing `test_combat_components.gd`: instantiated actors with arbitrary names each have independent health; 90-10=80, second actor=90; negative/NaN damage ignored, healing caps at maximum; lethal result KILLED emitted once, next attack IGNORED; enemy accepts damage without setting get_hited; normal projectile remains exactly one damage.
- [ ] Run new test and confirm expected missing component/contract assertion fails; no accidental parse error counts as RED.
- [ ] Implement health and attack objects, explicitly configure receivers. Keep take_damage/receive_attack/hurt/real_hp/health adapters. Existing bool receive_attack remains a compatibility adapter where true means blocked; new weapons use the explicit result interface.
- [ ] Route sword and bullet through CombatReceiver; display hit flash only for DAMAGED/KILLED. Actors without receiver keep projectile collision deletion. Guard uses an explicit adapter until Task 4; contact damage remains blockable=false and retains cooldown.
- [ ] Run new test plus full suite; expected all green, source whitespace check clean.
- [ ] Commit `refactor: unify health and attack reception`。

### Task 2: 单角色复活与通用携带/交付

**Files:** Create `components/respawn_component.gd`, `components/carry_component.gd`, `components/carryable_component.gd`, `components/delivery_receiver.gd`; Modify `maincharac.gd`, `winning_point.gd`, `wtable.gd` and scene wiring; Test `tests/test_lifecycle_components.gd` plus existing star/death tests。

**Interfaces:** RespawnComponent.configure(timer: Timer, spawn: Vector2, delay: float)、die() -> bool、respawn(position: Vector2) -> bool；died/countdown_changed/respawn_requested signals，dead/time_left properties。CarryComponent.configure(actor)、try_pick_up(item) -> bool、drop()、deliver_to(receiver) -> bool。CarryableComponent.can_pick_up(actor) -> bool、attach_to(holder)、release()、transfer_to(receiver) -> bool。DeliveryReceiver.can_accept(item) -> bool、accept(item) -> bool。

- [ ] Write failing lifecycle tests: two component instances keep independent dead/timer state; duplicate die returns false and does not extend countdown; carried item release at death preserves world position; freed carrier clears safely; delivered item cannot be reclaimed accidentally.
- [ ] Run new test; expected assertions fail because lifecycle/carry implementations absent.
- [ ] Extract dead state/timer operations; player adapter orchestrates collision, animation, weapons and health reset in original order. Enemy retains despawn death policy. Expose compatibility properties without duplicate state.
- [ ] Extract carrying/receiving while keeping star Area2D touch logic and original-holder overlap protection. Explicitly configure actor/item/table references, preserve no-gravity rule and already-overlapping-table delivery.
- [ ] Run lifecycle tests and full suite; especially original player identity, shared world, second death and death-zone re-entry assertions must remain green.
- [ ] Commit `refactor: extract respawn and carrying components`。

### Task 3: 移动组件与本地输入边界

**Files:** Create `components/character_motor.gd`; Modify `maincharac.gd`, player scene; Test `tests/test_character_motor.gd`。

**Interfaces:** CharacterMotor.configure(body: CharacterBody2D)、tick(delta: float, move_input: Vector2)、request_jump()、request_dash(direction: Vector2)、reset_state()；state properties can_dash/is_dashing/dash_dir/dash_timer/jump_count。Input is read only by player adapter; externally supplied commands can drive non-local actors.

- [ ] Write failing real-motion tests with CharacterBody2D and floor: horizontal speed 150, jump impulse -400 with one jump until landing, dash speed 360 for 0.2 seconds, gravity suppressed only during dash, landing restores jump/dash. Verify two motors do not share state, reset clears velocity and restores readiness, non-local player ignores local Input but accepts explicit motor commands.
- [ ] Run test; expected missing motor or command-path assertion failure.
- [ ] Extract original movement ordering, including horizontal remembered dash direction and animation decisions. Actor calls move_and_slide once per physics step; motor contains no Input calls. Preserve exported/proxied legacy fields and original sprite/particle updates.
- [ ] Run movement test and full suite, including dead player movement suppression.
- [ ] Commit `refactor: separate character movement from input`。

### Task 4: 武器协议、格挡组件与输入适配

**Files:** Create `weapons/weapon_base.gd`, `components/guard_component.gd`, `components/local_combat_input.gd`; Modify `gun.gd`, `sword.gd`, `weapon_controller.gd`, player scene; Test `tests/test_weapon_components.gd` and existing sword/guard tests。

**Interfaces:** WeaponBase.configure(actor: Node2D)、set_active(enabled: bool)、aim(direction: Vector2)、attack(direction: Vector2) -> bool、cancel_attack()、reset_state()。WeaponController.register_weapon(id: int, weapon)、equip_weapon(id)、cycle_weapon(step)、aim(direction)、attack(direction) -> bool。GuardComponent.configure(actor)、request_guard(enabled, direction)、tick(delta)、try_block(context) -> bool、reset_state()；changed/guard_changed/blocked signals。

- [ ] Write failing tests: configure gun/sword under arbitrary containers; third test weapon can register/switch/attack without controller special casing; remote controller never consumes local Input; external attack request works. Directional guard and clock are independent per instance, 600 steps at 1/60 exhaust the bar at 10 seconds, empty-to-full 15 seconds; inactive/dead cannot attack; cancelled windup never hits; large step crossing active sweep cannot miss its sector.
- [ ] Run new test, verify absent common contract/decoupling fails.
- [ ] Extract guard state and original time/cost logic; controller proxies compatibility methods/properties and updates component only once per frame. Blocked signal drives firework feedback via presentation adapter.
- [ ] Implement WeaponBase and migrate gun/sword without changing timings, geometry, texture transforms or damage. Keep start_swing/reset_combat_state compatibility aliases. Controller receives explicit weapon refs/registrations, never assumes ../Sword or Player. Configure by actor adapter after all nodes are ready.
- [ ] Move scroll/mouse handling to LocalCombatInput, leave old controller _unhandled_input/_process test-facing entry points as adapters during migration; their only input responsibility is delegated to input adapter, gameplay operations remain callable without Input.
- [ ] Run weapon test and entire suite; no change to right-side UI, exclusive gun/sword or remote-input tests.
- [ ] Commit `refactor: unify weapon and guard components`。

### Task 5: UI 绑定、表现分离、使用说明与最终验证

**Files:** Modify `combat_hud.gd`, `death_screen.gd`, `ui_hp.gd`, `main.gd`, feedback integration; Create `docs/gameplay-components.md`, `tests/test_component_binding.gd`。

**Interfaces:** UI adapters bind_actor(actor)/unbind_actor(); bind_player remains compatibility alias. Feedback public show_hit/show_block aliases preserve existing spawn helpers. Signals originate at state-owning components; no UI method changes game state.

- [ ] Write failing binding tests: bind A then B and update A, HUD still reflects B; repeated binding does not duplicate callbacks; null/freed/remote actor hides UI; binding immediately displays current HP/guard/death timer; two independent actors and arbitrary hierarchy work with explicit references.
- [ ] Run new test and confirm stale binding/old coupling is caught.
- [ ] Implement signal disconnection/reconnection and typed component access. Preserve exact fonts, positions, resource styles and local-only display. Presentation consumes result signals, keeps weak target reference and automatic cleanup, never mutates Engine.time_scale or tree pause.
- [ ] Document responsibility, public functions, scene setup, state ownership, local-command boundary and a minimal second actor/new weapon example; explicitly state actual network authority/replication is not implemented.
- [ ] Run all tests, full editor import/parse and actual render checks of idle, guarding, windup, sweep, hit, death/countdown and respawn. Compare baseline scene styles/resources/weapon transforms and ensure all gameplay assertions remain green.
- [ ] Commit `refactor: decouple component presentation and document reuse`。

## Final Review and Delivery

- [ ] Fresh whole-branch read-only review against stable baseline and spec, focusing on the five Review Focus cases. Fix critical/important issues with reproducing tests and one final green full-suite run.
- [ ] Verify develop remains 8b81567, working tree clean, commits on refactor/reusable-components only. Keep branch locally; do not merge or push without user instruction.
- [ ] Report component entry points, verification evidence and any deferred limitations. Actual future multiplayer behavior needs later authority/synchronization work and integration testing.
