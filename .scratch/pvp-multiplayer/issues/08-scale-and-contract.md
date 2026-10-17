# 08: 16 席压测与旧入口收缩

**What to build:** 在完整玩法闭环上验证最多 16 席的实际承载与故障恢复，并在所有 seam 通过后删除已经没有调用者的旧直接结算入口。

**Blocked by:** 07: 整局结束与地图配置切片.

**Status:** ready-for-agent

**Primary executor:** DeepSeek Pro/Qwen for harness and reporting; Codex performs final verification

- [ ] 使用可重复的多客户端测试逐步覆盖 2、4、8、16 席，并记录主机帧时间、snapshot 流量和状态收敛。
- [ ] 验证乱序、重复、延迟、短时丢包和断线不会产生重复伤害、重复掉落、重复撤离或错误席位。
- [ ] 60 Hz 权威物理与约 20 Hz snapshot 仅作为起点，按实测调整并记录最终范围。
- [ ] 完整运行 MatchAuthority、NetworkSession 与现有 SceneTree 三个 seam 的测试。
- [ ] 删除无调用者的旧直接伤害、拾取、交付与弹丸权威入口，单机仍通过离线 adapter 工作。
- [ ] 形成首版已验证能力与未覆盖网络条件清单，不把局域网结果宣传为公网保证。
