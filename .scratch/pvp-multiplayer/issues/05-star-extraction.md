# 05: 星星交付与个人撤离切片

**What to build:** 让两名玩家在同一局中争夺有限星星、交付到撤离点、取消或因死亡掉落，并让完成 30 秒读秒的玩家退出战斗进入观战。

**Blocked by:** 04: 剑、格挡、死亡与物品切片.

**Status:** ready-for-agent

**Primary executor:** Codex

- [ ] 先通过 MatchAuthority seam 测试 FREE、CARRIED、BOUND、CONSUMED 的唯一状态与星星守恒。
- [ ] 每个撤离点一次只绑定一颗星、一名交付者；其他玩家不能直接偷取 BOUND 星星。
- [ ] 普通受伤不打断，离开区域清零并退回 CARRIED。
- [ ] 交付者死亡使 BOUND 星星解绑并在死亡位置转为 FREE，不能继续留在桌上。
- [ ] 满 30 秒时玩家成功、星星消耗并进入观战；同刻致死攻击优先级符合规格。
- [ ] 两进程从拾取到撤离的 snapshot 与事件最终一致。

