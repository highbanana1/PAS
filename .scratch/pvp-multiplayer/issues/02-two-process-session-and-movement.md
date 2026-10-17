# 02: 两进程建房与移动同步

**What to build:** 让一个 host 和一个 client 通过真实 Godot ENet 加入同一房间，各自控制自己的角色并最终收敛到房主权威状态。

**Blocked by:** 01: 离线权威移动切片.

**Status:** in-progress

**Primary executor:** DeepSeek Harness；Codex 审查、整合与验收

- [ ] 先写真实 ENet host/client 的失败集成测试，验证连接、身份映射、生成与移动 snapshot。
  - [x] 02A：真实双进程连接、16 席边界、身份映射与命令信封验证已完成；移动 snapshot 留在 02B。
- [ ] remote sender 决定玩家身份，伪造身份或旧 match/life 命令会被拒绝。
- [ ] 房主与客户端使用相同命令路径；本地移动可预测，远端移动可插值并接受纠正。
- [ ] late join baseline 来自单一权威时刻，之后的事件不会因通道到达顺序重复应用。
- [ ] 断开 host 会结束房间并使 client 返回非战斗状态。
