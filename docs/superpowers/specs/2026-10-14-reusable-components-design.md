# PAS 可复用组件与统一接口设计

日期：2026-10-14
稳定基线：develop / 8b815675428a3251812ef53c32fd12c677fb9dc0
状态：已由用户审核，组件迁移与验证已完成；验证记录见同目录 reusable-components-verification 文档。

## 目标与范围

将现有游戏功能从具体玩家、敌人和场景路径中解耦，使新角色、新武器、新拾取物能够复用。
本轮范围为自有游戏代码、场景接线及测试；不改第三方插件、图片与字体。
保持当前玩法、数值、画面布局与输入方式。实际联机同步、连击、新敌人和数值平衡不在本轮范围。
通用的含义是组件有明确输入、输出、状态归属和依赖，而不是给每个旧函数增加一层包装。

## 必须保留的行为

- 滚轮切换枪与剑，左键使用当前武器，右键持剑防守；枪和剑互斥。
- 玩家移动、跳跃、冲刺的速度、方向规则及落地恢复行为保持不变。
- 剑一次点击只挥一次：45 毫秒蓄势、90 毫秒扫过、110 毫秒收剑；伤害 2，范围 36，角度 120 度。
- 蓄势与收剑没有伤害；扫过判定跟随剑刃，单刀对同一目标只伤害一次，墙壁阻挡近战。
- 子弹伤害 1、速度 700；碰到实体消失，忽略发射者，重复碰撞不重复结算。
- 格挡前方 140 度的子弹及可格挡近战；身体碰撞伤害绕过格挡。
- 蓝条上限 100，防守按每秒 10 消耗，非防守按每秒 100/15 恢复；成功挡住攻击额外扣 20。
- 蓝条耗尽自动结束防守，持续按住右键不自动恢复或重新举剑，松开后可恢复。
- 非防守的挥剑和持枪允许恢复蓝条；死亡期间不恢复，复活回满。
- 死亡后保留玩家节点和摄像机，禁用操作与碰撞，5 秒后满血返回出生点；世界继续运行。
- 玩家死亡掉下携带星星，无重力；复活不自动重新携带，原持有者离开拾取区后才能重新拾取。
- 星星交付桌子后跟随桌子；已站在桌子范围内再拾取也能交付。
- UI 只展示绑定的本地玩家；其他玩家的死亡和蓝条不影响本地玩家。
- 保留像素界面、短刀光、目标白色闪光、格挡火花；表现不改变全局时间或暂停状态。

## 组件结构

新增 `scene/script/components/`、`scene/script/combat/` 和 `scene/script/weapons/`。
组件默认继承 Node，通过导出节点引用或显式 configure 传入依赖。
Gun、Sword 共享 WeaponBase（Node2D）；各自保留枪口、贴图和攻击实现。
既有 `.tscn` 与入口脚本路径保留，减少场景资源和 UID 变化。

| 模块 | 状态归属与责任 | 主要公开接口与通知 |
| --- | --- | --- |
| HealthComponent | 当前/最大生命，伤害和治疗的边界检查 | apply_damage(amount)、heal(amount)、restore_full()；changed、depleted |
| RespawnComponent | 单个角色的死亡标记、出生位置、倒计时；可选自动复活 | die()、respawn(position)、reset_spawn(position)；died、countdown_changed、respawn_requested |
| CharacterMotor | 移动、重力、跳跃次数、冲刺状态；不读取本地鼠标或键盘 | tick(delta, move_input)、request_jump()、request_dash(direction)、reset_state() |
| CombatReceiver | 接收攻击、尝试格挡、调用生命组件，返回明确结果 | receive_attack(context) -> AttackResult |
| GuardComponent | 蓝条、格挡状态、朝向与角度、耗尽规则 | request_guard(enabled, direction)、tick(delta)、try_block(context)、reset_state()；changed、guard_changed、blocked |
| WeaponBase | 武器一致生命周期，持有者引用；子类实现实际攻击 | configure(actor)、set_active(enabled)、aim(direction)、attack(direction) -> bool、cancel_attack()、reset_state() |
| WeaponController | 注册武器、切换武器、向当前武器转发请求；不直接读取 Input | register_weapon(id, weapon)、equip_weapon(id)、cycle_weapon(step)、aim(direction)、attack(direction)；weapon_changed |
| CarryComponent | 单个角色持有什么；拾取、释放和交付的统一入口 | try_pick_up(item)、drop()、deliver_to(receiver) -> bool；item_changed |
| CarryableComponent | 当前持有者、跟随偏移、落下后原持有者的拾取限制 | can_pick_up(actor)、attach_to(holder)、release()、transfer_to(receiver) |
| DeliveryReceiver | 接收物品、持有已交付物；保留桌子的重复交付保护 | can_accept(item)、accept(item) -> bool；delivered |
| CombatFeedback | 短暂视觉实例，弱引用目标，独立清理 | show_hit(target, position)、show_block(actor, direction) |
| UI 适配器 | 订阅组件通知与刷新视图，负责绑定/解绑 | bind_actor(actor)、unbind_actor() |

`maincharac.gd` 留作玩家组装与输入适配层：读取 Input、发送移动/武器请求、响应死亡与复活通知、更新动画。
`enemy.gd` 保留巡逻决策与射线转向；复用生命和受击组件，仍在死亡后删除，默认不自动复活。
玩家与敌人的决策不同，不把敌人巡逻强行塞入玩家输入组件。

## 统一攻击契约

AttackContext 使用每次攻击独立创建的 RefCounted 值对象，包含 amount、origin、source、blockable。
源节点使用前检查有效性，不假定攻击者始终存在；origin 是命中时需要的攻击来向，不随发射者后续移动改变。
AttackResult 为明确枚举：IGNORED、BLOCKED、DAMAGED、KILLED。

规则：
1. 已死亡目标、无效目标、非有限或非正伤害返回 IGNORED，伤害入口不隐式执行治疗。
2. blockable 且符合格挡方向和资源条件时，扣条、通知表现，返回 BLOCKED。
3. 否则向 HealthComponent 结算，依据生命状态返回 DAMAGED 或 KILLED。
4. 子弹与剑调用同一攻击入口，不再依靠敌人的 get_hited 标记才能扣血。
5. 身体接触使用 blockable=false，并保留原接触伤害冷却，避免每帧扣血。
6. 接触无战斗组件的普通物体时子弹仍消失；剑忽略不接收攻击的对象。
7. 命中闪光只在 DAMAGED/KILLED 播放，格挡火花只在 BLOCKED 播放。

武器不负责玩家键盘事件，也不负责直接查找具体玩家类型或修改 UI。
实际攻击发起仍由本地输入适配层控制；未来可由 AI 或网络命令调用相同入口。

## 单一状态来源与兼容

每个角色有各自的组件实例，生命、蓝条、携带物、倒计时不得存在静态变量或共享 Resource 中。
HealthComponent 是血量唯一来源，GuardComponent 是蓝条唯一来源，RespawnComponent 是死亡状态唯一来源。
玩家入口保留 take_damage、receive_attack、respawn 及旧通知名，转发到组件，避免一次性破坏场景接线。
迁移期间 real_hp、max_hp、is_dead、respawn_delay、current_winning_point 等既有公开属性可用访问器代理，不能复制一份独立状态。
敌人的 hurt/health 入口在迁移期保留代理；历史接触入口适配后，生产攻击链路不再设置 get_hited/get_hit 来发送武器伤害。
保留现有 WeaponController、gun、Sword 节点路径及 ID 0/1，UI 根据注册武器的数据更新图标。
旧的 recover_guard(delta) 可保留转发兼容名，实际更新由 GuardComponent.tick(delta) 执行且每帧只调用一次。
兼容入口仅为迁移和现有场景提供桥接；新代码使用统一接口。

## 生命周期与界面

组件之间通过显式引用与信号协作，构造时不假定固定的 `../Sword`、`$gun` 或 Player 类。
装配后再初始化组件；配置缺失在编辑器/启动时给出明确错误，不在每帧静默失败。
死亡通知的顺序为：标记死亡 → 取消攻击/防守/移动 → 释放携带物 → 禁用角色碰撞与显示 → 开始本人倒计时。
复活通知由玩家入口响应：恢复位置、生命、移动状态、碰撞、武器与蓝条，最后通知 UI。
死亡/复活调用均保持幂等；重复致死攻击不重开倒计时。
UI 重新绑定时先断开上一对象的通知，解绑或目标删除后隐藏；订阅完成后立即刷新初值。
表现节点只消费事件，不能发伤害、扣蓝条或改全局时间。

## 迁移顺序

1. 增加通用生命与攻击契约，迁移玩家、敌人、子弹受击；保留旧入口代理。
2. 提取单角色复活与携带组件，恢复完整的死亡/掉落/交付链路。
3. 提取 CharacterMotor，保留现有输入节奏、动画和冲刺规则，补充真实运动回归。
4. 提取 GuardComponent、WeaponBase，统一枪和剑生命周期与攻击入口，隔离本地输入。
5. 调整 UI 绑定与表现通知，删除已失去用途的内部耦合，补充组件使用说明和最小复用示例。

每一步完成后运行对应组件测试与整套游戏回归，并形成可回退提交；所有步骤通过才算本轮完成。
第三方插件不纳入组件重构，稳定 develop 分支不合并重构中的半成品。

## 验收与验证

- 稳定基线的 118 项检查保持通过；只在确有接口迁移时更新测试接线，不删除玩法断言。
- 补充独立组件测试：不同节点名/不同父节点可复用、实例状态隔离、伤害结果与通知一致、无效请求不破坏状态。
- 补充真实玩家移动、跳跃、冲刺和重置测试，避免现有测试多数禁用角色物理而漏掉移动回归。
- 验证第二个角色独立受伤/防守/复活，远端标志角色不接收本地输入。
- 验证枪和剑只使用统一受击入口，对敌人不再要求先设置命中标记。
- 验证 UI 重绑定不重复订阅、旧玩家通知不再刷新新玩家界面。
- 运行项目全量导入/脚本解析及实际渲染检查，确认像素字体、蓝条、武器图标与局部特效保持原样。
- 提供组件职责、公开接口、场景装配步骤和新角色/武器接入示例。

## 风险与处理

- 初始化顺序：通过装配入口显式配置后启动，避免子节点 _ready 先于父节点而读取未初始化状态。
- 双重更新：旧入口只能转发，不保留第二套计时、血量或攻击处理。
- 物理回调：保留碰撞层变更的延迟设置，扇形命中继续在物理步骤结算。
- 架构过度：仅抽象现有共用行为；不做全局事件总线、万能管理器、完整背包或联机框架。
- 工作范围：项目自身游戏功能组件化，不承诺把 Godot 回调、第三方插件和每一行表现代码都做成通用工具函数。

## 审核后的下一步

用户已批准设计与计划，并选择直接在当前重构分支执行。五批迁移、完整测试、独立复查及修复已完成；使用说明见 docs/gameplay-components.md，结果见 2026-10-14-reusable-components-verification.md。
