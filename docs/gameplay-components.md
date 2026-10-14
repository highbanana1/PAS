# PAS 游戏组件使用说明

稳定基线：`develop / 8b81567`。重构保持原有数值、输入和表现；尚未实现实际网络同步与权限判定。

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
