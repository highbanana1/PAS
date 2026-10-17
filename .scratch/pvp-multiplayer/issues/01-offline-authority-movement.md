# 01: 离线权威移动切片

**What to build:** 让一个离线玩家的移动、跳跃、冲刺、死亡与复活通过 MatchAuthority 的公开 interface 推进，同时保持当前单机输入、画面和数值体验。

**Blocked by:** None (can start immediately).

**Status:** complete

**Primary executor:** DeepSeek Harness；Codex 审查、整合与验收

- [x] 先用 MatchAuthority seam 写出玩家命令、固定步进、snapshot 与生命周期事件的失败行为测试。
- [x] 房主本地输入也进入同一命令队列；离线 adapter 不允许直接写权威生命或位置。
- [x] 非本地或断线角色可以由权威步进推进，不再依赖本地键盘开关。
- [x] 死亡与 5 秒复活、五格生命和角色状态刷新保持现有行为。
- [x] 现有 29 组 SceneTree 回归测试全部通过；新增权威测试后共 30 组、428 项断言通过。
