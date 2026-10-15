# Health Item Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [x]`) syntax for tracking.

**Goal:** 实现独立回血物品、E 满储量扩容、长按 3 治疗、F 拾取、敌人概率掉落和玩家死亡掉落。

**Architecture:** 每件物品使用独立数据实例保存剩余 HP，角色组件持有列表并执行使用命令。本地输入仅转发命令；地面节点负责拾取转移，掉落组件负责生成，UI 仅订阅状态。

**Tech Stack:** Godot 4.7.2 / GDScript / SceneTree 回归测试。

**Spec:** ../specs/2026-10-14-health-item-design.md

## Global Constraints

- 项目根目录 D:/develop/godot/new-game-project；只在 refactor/reusable-components 执行，master、develop 不改动。
- 保留所有既有未提交改动，尤其用户自己的 scene/maincharac.tscn；不覆盖或整文件回退。
- 使用 asset/pic/healthitem.png，不改原图文件。每件容量等于角色每格 HP，当前为 30。
- E 仅选中且满储量时扩容一格并增加等量当前 HP，最多八格；3 短按选择，0.3 秒后持续治疗，完整容量消耗需 2 秒。
- 敌人掉落率 25%、拾取距离 40 可在 Inspector 调整；开局不赠送。死亡掉落所有物品，保持各自剩余储量；复活物品栏为空且恢复五格血。
- 不暂停世界，不修改枪、剑或格挡数值；所有状态归各角色实例，实际网络同步不在本轮范围。

## Review Focus

- 满血或已八格时使用失败，不消耗储量；部分储量不得扩容。
- 同一世界物品连续被两个角色请求拾取时只发放一次，部分储量转移保持原值。
- 3 按键重复事件不重复启动使用；短按、松开、切武器、死亡都按规则停止。
- 角色死亡一次只掉落一次，空背包不生成物品，复活不自动拾取。
- 远程角色不读取本地输入或占用本地 UI；持有物品与武器输入互不串状态。

## Verification Command

使用 D:/games/steamapps/common/Godot Engine/godot.windows.opt.tools.64.exe，以 Start-Process -WindowStyle Hidden -Wait -PassThru 运行 --headless --path D:/develop/godot/new-game-project --script res://tests/<test>.gd --quit-after 1800。检查进程退出 0、RESULT: 0 failures、标准错误为空。

### Task 1: 物品储量与角色使用组件

**Files:** Create scene/script/items/health_item_data.gd, scene/script/components/health_item_component.gd, tests/test_health_item.gd. Modify scene/script/maincharac.gd（装配与生命周期接口）。

**Interfaces:**
- HealthItemData RefCounted: capacity: float, remaining: float; is_full() -> bool; consume(amount: float) -> float。
- HealthItemComponent: configure(actor: Node2D) -> void; add_item(item: RefCounted) -> bool; select_item() -> void; deselect_item() -> void; use_selected() -> bool; begin_continuous_use() -> void; tick_continuous_use(delta: float) -> void; cancel_use() -> void; take_all_items() -> Array。
- changed 信号供 UI 读取 items、selected、当前 remaining/capacity；玩家 get_health_item_component() -> Node。
- 使用 actor.get_health_component().heal() 返回的实际治疗量扣储量；扩容通过 max_hp/real_hp 兼容接口执行并检查八格容量。

- [x] 写失败测试：current=120/max=150、完整物品 E 后 max=180/current=150 且物品移除；remaining=15 时 E 失败不消耗；max=240 时失败；长按治疗 1 秒恢复 15 并消耗 15；满血消耗 0；两实例储量互不影响；死亡后组件停止治疗。
- [x] 运行 test_health_item.gd，确认失败对应缺失接口或行为。
- [x] 实现上述数据与组件接口；剩余量使用浮点数，拒绝 NaN/负数时间和数量，耗尽时只移除当前实例。
- [x] 运行 test_health_item.gd 至通过，更新组件文档。只显式暂存本任务文件并在当前重构分支提交；不包含用户角色场景改动。

### Task 2: 地面拾取、敌人及玩家死亡掉落

**Files:** Create scene/health_item_pickup.tscn, scene/script/items/health_item_pickup.gd, scene/script/components/health_item_drop_component.gd, tests/test_health_item_pickup.gd. Modify scene/script/enemy.gd, scene/script/maincharac.gd。

**Interfaces:**
- HealthItemPickup: configure(item: RefCounted) -> void; can_pick_up(actor: Node2D) -> bool; try_pick_up(actor: Node2D) -> bool。持有每件数据，加入 health_item_pickup 组。
- HealthItemDropComponent: spawn_item(item: RefCounted, at: Vector2) -> Node2D; drop_enemy_loot(at: Vector2) -> void; drop_inventory(items: Array, at: Vector2) -> void。敌人死亡只调用一次概率判定，默认 0.25 可导出；0 和 1 边界可确定测试。
- 玩家死亡先 cancel_use，再 take_all_items 并在死亡位置生成地面节点；复活不填充物品栏。地面节点不自动拾取，无重力，多个物品用小幅水平间距防止完全重叠。

- [x] 写失败测试：40 距离内拾取成功、范围外失败、死人失败、同件仅成功一次、partial=12 拾取后仍为 12；概率 0 无掉落/1 掉落一次；玩家持 full=30/partial=12 死亡后地面两件、物品栏空、复活仍空、手动重拾后数值不变；死亡重复调用不重复掉落。
- [x] 运行 test_health_item_pickup.gd 确认失败。
- [x] 实现地面节点、概率掉落及两类死亡接线；敌人 queue_free 改为死亡处理末尾调用，世界物品放在存活的世界节点下。
- [x] 运行拾取及已有死亡/星星测试至通过，显式提交本任务文件。

### Task 3: 本地按键、物品栏进度与集成验证

**Files:** Create scene/script/components/local_item_input.gd, tests/test_health_item_input.gd. Modify project.godot, scene/script/maincharac.gd, scene/script/combat_hud.gd, scene/combat_hud.tscn, docs/gameplay-components.md。

**Interfaces:**
- LocalItemInput: configure(actor: Node2D, items: Node) -> void; handle_event(event: InputEvent) -> bool; tick(delta: float) -> void; reset_state() -> void。
- actions item_select_1=3, item_use=E, item_pickup=F；不修改已有武器和 interact 映射。只本地存活角色处理，3 长按阈值 0.3 秒，重复事件不重置计时。
- UI 第一个物品槽显示图片、3 标签、剩余 HP 进度和件数；其余槽为空。bind_actor/unbind_actor 对新信号成对连接和清理。
- 1/2/滚轮切武器取消物品选择与长按计时；F 从范围内最近的一件发起拾取，平距时按实例 ID 固定次序。E 只使用已选中物品。

- [x] 写失败测试：短按 3 不消耗，长按每帧按实际时间恢复，松开停止；部分物品 E 不耗、完整 E 扩容；武器切换停止治疗；死亡后松键/复活不继续使用；远程角色忽略按键；枪剑仍可正常攻击。
- [x] 运行 test_health_item_input.gd 确认失败。
- [x] 实现输入与 UI，图片用纹理区域显示有效像素，保持最近邻和现有底栏比例；重置只清理本人输入状态，不全局释放 Input。
- [x] 运行三个新增测试和所有现有 test_*.gd；运行 headless editor recovery-mode import，要求退出 0 且无错误。
- [x] 渲染满储量、部分储量、空物品栏和地面拾取提示，检查 640x360/1152x648 两种尺寸；核实图片未被改写。
- [x] 请求一次完整代码审核，修复重要问题；核实 master/develop 引用未变且用户角色场景文件未覆盖。显式提交本任务文件，不推送、不合并稳定分支。
