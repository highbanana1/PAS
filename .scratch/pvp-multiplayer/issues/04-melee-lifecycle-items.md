# 04: 剑、格挡、死亡与物品切片

**What to build:** 让两名联网玩家的剑击、格挡、死亡复活、背包与一次性物品掉落由房主统一裁决，并保持当前玩法手感和数值。

**Blocked by:** 03: 权威霰弹枪命中切片.

**Status:** ready-for-agent

**Primary executor:** DeepSeek Pro; Codex reviews, tests, and integrates

- [ ] 先写剑击 action 标识与目标 life 标识去重的失败行为测试。
- [ ] 格挡方向、格挡条消耗、耗尽锁定、恢复和攻击取消格挡由权威状态验证。
- [ ] 武器伤害不擅自继承只属于接触伤害流程的受击无敌时间。
- [ ] 死亡、复活与状态刷新在两端一致，世界不会因单个玩家死亡暂停。
- [ ] 网络物品使用稳定类型、数值、归属和 revision；不传 Node、Resource、WeakRef 或纹理。
- [ ] 背包和物品死亡掉落只执行一次，拾取争抢由权威决定唯一胜者。

