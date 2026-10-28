# 07: 整局结束与地图配置切片

**What to build:** 完成星星配额、10 分钟计时、参赛者定义、三种整局结束条件、个人胜负、观战 HUD 与地图撤离配置。

**Blocked by:** 06: 中途加入与断线重连切片.

**Status:** completed (local Ticket 07)

**Primary executor:** DeepSeek Pro; Codex reviews, tests, and integrates

- [x] 开局生成 ceil(开局参赛人数/4) 颗星，中途加入不增加配额。
- [x] 10 分钟截止、全部星星消耗或所有参赛者离场会结束本局，未撤离者失败。
- [x] 撤离完成与 10 分钟截止同刻时先提交撤离成功。
- [x] 观战者与重连超时移除者不算参赛者；等待复活与保留角色仍算。
- [x] 撤离点数量与普通敌人由地图配置，首张 PvP 验证地图关闭普通敌人。
- [x] 客户端显示与权威一致的个人结果、观战状态和整局结果。

**Verification (2026-10-28):** Godot 4.7.2 on the D: project: 53 of the 54 existing SceneTree tests reached RESULT: 0 failures in the batch; reconnect-expiry exceeded the 20-second limit and passed separately with a longer limit. The new PvP result/spectator regression test also passed. The independent PvP scene loaded in the editor with zero errors and warnings before the final HUD change; the new script compiled in the regression test.
