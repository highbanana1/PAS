# PAS 游戏组件使用说明

稳定基线：`develop / 8b81567`。组件重构后的玩法调整见下文；尚未实现实际网络同步与权限判定。

## 状态在哪里

组件脚本在 `scene/script/components/`，攻击契约在 `scene/script/combat/`，武器基类在 `scene/script/weapons/`。
当前玩家在 `_init()` 创建组件、在 `_ready()` 显式配置依赖；现有场景中的 gun、Sword、WeaponController、Timer 与 RespawnTimer 路径保持原样。

| 组件 | 负责 | 公开入口 |
| --- | --- | --- |
| HealthComponent | 单个角色的血量 | configure、apply_damage、heal、restore_full；changed/depleted 信号 |
| CombatReceiver | 统一受击及格挡优先结算 | configure、receive_attack；static deliver；attack_received 信号 |
| RespawnComponent | 单个角色的死亡标记与复活计时 | configure、die、respawn、reset_spawn；died/countdown_changed/respawn_requested 信号 |
| CharacterMotor | 移动、跳跃、冲刺状态 | configure、tick、request_jump、request_dash、reset_state |
| GuardComponent | 蓝条、格挡方向及持续时间 | configure、request_guard、tick、try_block、reset_state；changed/guard_changed/blocked 信号 |
| WeaponController | 注册、选择和驱动武器 | configure、register_weapon、equip_weapon、cycle_weapon、aim、attack |
| CarryComponent | 角色携带什么 | configure、try_pick_up、drop、deliver_to |
| CarryableComponent | 物品跟随谁、落下/交付与重拾限制 | configure、can_pick_up、attach_to、release、transfer_to、follow、settle_pickup |
| DeliveryReceiver | 接受一个物品 | configure、can_accept、accept；delivered 信号 |
| LocalCombatInput | 读取本机鼠标和滚轮 | configure、tick、handle_event；仅由本地角色调用 |
| CombatPresentation | 订阅格挡事件并显示火花 | configure；不修改战斗状态或全局时间 |
| PlayerHurtPresentation | 玩家专用闪白、视觉后仰和短闪烁 | configure、reset_state；订阅本人 receiver，死亡立即清理 |
| EnemyHurtPresentation | 敌人专用闪白和轻微压缩回弹 | configure、reset_state；子弹与剑共用本人受击入口 |

Actor 的 `get_health_component()`、`get_combat_receiver()`、`get_respawn_component()`、`get_motor()`、`get_carry_component()`、`get_guard_component()`、`get_weapon_controller()` 暴露已装配实例。
兼容属性 real_hp、max_hp、is_dead、spawn_position、respawn_delay、current_winning_point 及移动状态均转发到组件，没有第二份状态。

## 新角色与统一受击

在角色中创建 HealthComponent 和 CombatReceiver 子节点，初始化完成后显式配置：

```gdscript
const Health = preload("res://scene/script/components/health_component.gd")
const Receiver = preload("res://scene/script/combat/combat_receiver.gd")
const Context = preload("res://scene/script/combat/attack_context.gd")
var health = Health.new()
var receiver = Receiver.new()

func _ready():
    add_child(health)
    add_child(receiver)
    health.configure(90)
    receiver.configure(self, health)
    health.depleted.connect(on_death)

func get_combat_receiver():
    return receiver

func on_death():
    queue_free() # 敌人策略；玩家使用 RespawnComponent 保留节点
```

攻击调用 `Receiver.deliver(target, Context.new(10, origin, attacker, true))`。
结果是 IGNORED、BLOCKED、DAMAGED 或 KILLED；身体接触使用 `blockable=false`，接触伤害冷却由角色适配层保留。
伤害必须为正有限值，非法伤害忽略；治疗调用 heal，不用负伤害隐式治疗。
持有者可选传入格挡处理 Callable；当前玩家将 WeaponController.try_block 作为适配器接入。

## 增加武器

继承 WeaponBase，并实现 attack(direction)；默认 return false 表示请求不受理。

```gdscript
extends "res://scene/script/weapons/weapon_base.gd"
func attack(direction: Vector2) -> bool:
    if not can_attack(): return false
    aim(direction)
    # 在这里创建实际攻击；命中后按需要发出 attack_resolved(target, result)。
    return true
```

将实例添加到任意挂载节点，再调用 `controller.register_weapon(2, weapon)`。
控制器会配置 actor/controller 引用并管理激活状态；`controller.cycle_weapon(1)` 按注册的数字 ID 循环。
枪和剑分别使用 0 和 1；玩家按数字键 1 切枪、2 切剑，也可继续用滚轮切换。当前底部显示两个武器槽和三个空物品槽；物品槽不绑定携带状态，新武器的图标槽需另加 UI。
新的武器不应读取 Input；设置 supports_guard 可启用格挡；持续攻击应实现 is_busy、cancel_attack 和 reset_state。
武器必须在树中并完成自身资源初始化后注册；控制器须先 configure(actor)。

## 外部命令与未来联机边界

本地移动输入只由 Player 适配层读取，鼠标、滚轮和武器数字键只由 LocalCombatInput 读取。
本地战斗输入需要显式设置 `is_locally_controlled=true`。普通 Node2D/敌人没有该标记时默认不接收本机鼠标与滚轮；设置 false 同样会阻止这些本地输入，但不阻止明确的命令调用：

```gdscript
actor.get_motor().request_jump()
actor.get_motor().tick(delta, Vector2.RIGHT)
actor.move_and_slide() # 每个物理步骤仅调用一次
actor.get_weapon_controller().equip_weapon(1)
actor.get_weapon_controller().attack(direction)
```

外部驱动者负责在正确的物理步骤调用移动，在每帧/固定步骤调用格挡 tick，不能与本地适配器重复推进同一组件。
所有角色独立保存生命、蓝条、携带物和计时器，不使用共享运行时 Resource 或全局变量。
实际联机接入仍需明确服务器权威、输入验证、伤害裁决与状态/表现同步；目前没有 RPC 和自动复制。

## UI 与表现

生命、死亡、战斗 UI 支持 bind_actor(actor) / unbind_actor()，重新绑定会先断开旧信号，删除目标会自动隐藏。
bind_player 为兼容别名（战斗/死亡界面）。界面只显示本地角色。
CombatPresentation 只订阅格挡组件的 blocked。玩家和敌人各自有独立的受击表现组件，订阅自己的 CombatReceiver.attack_received；敌人的子弹与剑统一走同一动画，攻击者不再重复播放目标受击。玩家只改变贴图材质、角度和透明度，不改角色位置、速度、控制或无敌规则。死亡立即恢复玩家贴图状态。两套表现都不影响暂停或 Engine.time_scale。
组件本身不直接寻找 UI 节点或显示特效。

## 验证

运行 `tests/test_*.gd` 下全部 SceneTree 测试；补充测试覆盖独立生命、复活、携带、真实移动、武器挂载、外部命令及 UI 重新绑定。
编辑器完整导入用于解析全部脚本；实际渲染检查像素界面、刀光、闪光、格挡火花和死亡/复活表现。

## 玩家分格血量

玩家 Inspector 的 starting_health_cells 默认 5，最多 8；health_per_cell 默认 30，因此开局 150 血，上限 240 血。运行时 max_hp 兼容接口会限制在八格容量内，复活恢复开局的五格血量；已获得的最大血量容量保留。

HealthComponent.damage_cell_size 大于零时，每次 apply_damage 最多扣完当前格，溢出直接丢弃。例如剩 125 血受到 15 点伤害后剩 120 血；下一格仍为 30 血。默认值 0 保留普通伤害结算，敌人不启用分格规则。

UI 保留原 bar1/bar2/bar3 接口，get_health_cells 返回八个独立格子的引用。耗尽的整格连同边框一起隐藏，治疗后可以重新显示。

小怪 contact_damage 默认 15，可在 Inspector 修改。身体接触调用玩家 queue_contact_damage(amount, origin)，沿用角色自己的受击无敌计时，并禁止剑格挡碰撞伤害。

格挡耗尽后 GuardComponent.exhausted 锁定再次格挡，恢复到满条后才解除；耗尽恢复期间右键请求无效，持续按住也不会扣条或暂停恢复；时间消耗和挡住攻击扣空都采用此规则。reset_state 会补满并清除锁定。复活同时清理格挡请求、攻击冷却、受击动画与受击计时，恢复跳跃、冲刺和零速度；各角色单独重置，不影响世界或其他角色。


攻击指令优先于格挡：WeaponController.attack 会先解除格挡，LocalCombatInput 在左键按下当帧优先发出攻击指令。挥剑期间不可重新格挡；动作结束后若仍请求防守且蓝条未锁定，则恢复格挡。蓝条耗尽锁定仅限制防守，不限制攻击。

## 回血物品

HealthItemData 保存单件 capacity/remaining，HealthItemComponent 持有每名角色独立的 items 列表。玩家 get_health_item_component() 返回组件；add_item、select_item、use_selected、begin_continuous_use、tick_continuous_use、cancel_use、try_pick_up、pick_up_nearest、take_all_items 是统一命令入口，组件不读取本地 Input。

默认一件存储 30 HP。短按 3 只选择，长按超过 0.3 秒开始持续治疗，2 秒消耗一件完整储量；仅实际恢复的 HP 扣除储量，满血不浪费。选中后按 E，仅全满储量可增加一格最大血量和当前血量并消耗，最多八格；部分物品可继续治疗，但不能扩容。选武器 1/2/滚轮取消物品选择与持续使用，枪剑攻击机制保持原样。

LocalItemInput 单独处理本地 3/E/F。F 拾取距离内最近一件地面物品；同件物品只成功转移一次。底栏三个槽位按拾取顺序显示各件物品图片；支持持续使用的物品显示剩余储量，不显示星星。

独立场景 scene/health_item_pickup.tscn 可以直接拖入关卡，stored_hp 默认 30、pickup_distance 默认 40。HealthItemDropComponent.spawn_item/drop_enemy_loot/drop_inventory 分别供定点生成、概率战利品、背包掉落调用。Enemy.health_item_drop_chance 默认 0.25，在 Inspector 调整；每次死亡只判定一次。

玩家 Inspector 的 health_item_use_duration 与 health_item_hold_threshold 分别控制使用时长和长按阈值。死亡会取消使用、在死亡位置掉落所有物品且保持各自剩余储量；复活物品栏为空，恢复五格血并保留已增加的最大容量。物品不会自动回到角色身上，也不会因复活补满。地面掉落不使用重力。真实网络权限与复制尚未实现，命令接口和每角色独立状态可用于后续接入。

## 通用顺位物品栏与一次性跳跃

当前统一入口是 Player.get_inventory_component()。旧 get_health_item_component() 和 health_item_component.gd 保留为兼容入口，返回同一份通用物品栏状态，没有第二份背包。

InventoryComponent 提供三个通用槽，按拾取先后排列；3、4、5 对应槽位下标 0、1、2，E 调用当前物品 use_once。消耗后后面的物品前移，背包满时拒绝拾取且地面物品保留。长按槽位键仅对 supports_continuous_use 的物品生效；持续输入绑定原物品实例，物品消耗或切换后立即停止，避免误用前移后的物品。

ItemData 是独立物品契约：kind、capacity、remaining、holder、icon、icon_region，以及 use_once(actor)、supports_continuous_use()、heal_continuously(actor, amount)。HealthItemData 保留 E 全储量扩容和长按实际治疗量扣储量；JumpItemData 使用 asset/pic/jumpitem.png，E 消耗一件并授予一次额外空中跳跃机会，不自动起跳。已有机会时拒绝再次使用且不消耗物品；机会只在普通跳跃耗尽后的下一次空中跳跃消耗，不永久增加跳跃次数，死亡/移动重置清除。

跳跃物品独立场景：scene/jump_item_pickup.tscn，可直接拖入关卡。ItemPickup 处理共用 F 拾取、图标与距离提示，按数据类型显示图片；原回血场景仍可用。敌人回血掉落概率保持原值，本轮未新增跳跃物品的随机掉落策略。死亡会掉落所有尚未使用的混合物品，保持各自数据，复活背包为空。

CharacterMotor.grant_extra_air_jump() -> bool 是外部授予临时机会的接口。初始状态及落地恢复仍为一次普通跳跃，枪、剑、格挡、冲刺和世界运行保持原样。
