# PAS 组件化验证记录

日期：2026-10-14。基线：develop / 8b81567。工作分支：refactor/reusable-components。

## 完成范围

独立生命、统一攻击结果、复活、携带/交付、移动、武器注册、格挡、本地输入适配、表现事件和 UI 绑定。
游戏 scene 资源、project.godot、图片、字体及第三方插件相对稳定基线没有改动。
每批迁移通过全量测试并独立提交。旧属性/调用保留代理，不复制组件状态。

## 最终自动检查

| 测试 | 通过断言数 |
| --- | ---: |
| test_bullet_impact | 6 |
| test_character_motor | 14 |
| test_combat_components | 10 |
| test_component_binding | 11 |
| test_death_respawn | 31 |
| test_guard_timing | 18 |
| test_lifecycle_components | 10 |
| test_star_respawn_pickup | 8 |
| test_star_table | 11 |
| test_sword_feel | 18 |
| test_sword_guard | 26 |
| test_weapon_components | 20 |
| 合计 | 183 |

所有测试进程退出码 0，末行 RESULT: 0 failures，stderr 无脚本错误。基线 118 项玩法断言保留，新增 65 项组件及边界断言。
编辑器 recovery-mode 全量导入退出码 0，stderr 为空。
Compatibility 实际渲染进程退出码 0，stderr 为空；检查持枪、格挡、格挡火花、蓄势、扫过、命中闪光、死亡、倒计时与复活截图。
最终修复后的自动截图同样成功保存，画面资源保持原样。

## 独立复查与修复

一次全分支只读复查，以稳定基线、设计及执行计划为依据；复查者未运行测试或修改代码。

- 独立冲刺请求未同时带移动输入时方向错误：新增左向与对角请求断言，先失败，再修复请求 X 分量的使用。
- 普通角色错误默认接收本地鼠标输入：新增瞄准/开火/滚轮断言，先失败，再改为 is_locally_controlled=true 显式启用。
- 已释放武器阻塞循环选择：新增释放后切换断言，先失败，再清理失效注册；追加待释放武器不得攻击的失败测试并修复。
- 兼容 health_changed 在复活时重复发送：新增单次通知断言，先失败，再移除重复显式发送。

复查发现的三项 Important 与自行发现的兼容通知问题均已修复，最终全量测试 183/183。无保留的复查 Minor 项。

## 审核范围与边界决策

- Ruling: 实际联机同步与权威裁决不在本轮实现范围；遵循已审核设计，仅隔离输入与实例状态。若这一边界不足，后续联机阶段仍需补充同步实现及多人集成验证。
- Ruling: 保留基线的远端接触伤害策略、剑的碰撞层与目标组规则；本轮不改变现有玩法。若后续联机玩法需要改变这些规则，应以专门回归与联机测试验证。

本轮提供可复用命令入口，不宣称已经验证实际网络延迟、同步或服务器权威行为。

## 交付

使用说明：docs/gameplay-components.md。
稳定 develop 保持 8b81567。重构分支本地保存，不自动合并或推送。
