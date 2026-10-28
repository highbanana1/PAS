# Ticket 08 云端实现与验收记录

## 实施结果

- 高频移动世界状态按权威 `server_tick` 分片，每个 Variant 载荷预算为 1200 字节，为观测到的 1392 字节 ENet MTU 和 RPC 封装保留余量。
- 每片携带 `snapshot_chunk_index`、`snapshot_chunk_count` 和 `snapshot_player_count`；每个玩家状态继续携带稳定 `player_id`、`tick`、`revision` 与 `ack_sequence`。
- 客户端只在同一 epoch/tick 的全部分片到齐且玩家总数匹配后原子应用。更新 tick 会丢弃旧 tick 的不完整缓存；迟到旧片不能与新 tick 混合。
- 桥接层记录移动 snapshot 的批次数、实际包数、Variant 字节总量和最大包大小，也记录可靠 combat 包的次数、字节总量和最大包大小。
- 可靠 combat 检查点只重复生命、死亡、血量、在线、撤离和观战等必须抗丢包的玩家字段；位置、速度、guard 和 items 继续由各自域承载，避免每个 combat 包复制完整玩家快照。
- ENet 传输层在权威席位上限之外保留一个拒绝握手槽；满 16 席时，第 17 个连接仍能收到 `room_full`，但不会取得玩家身份。
- 房间上限、30 秒原身份重连、过期后新永久 ID、开局星星冻结、三种整局结束、胜者观战和房主离开停止客户端命令均沿用 Ticket 06/07 的权威实现及测试。

## 新增验收

`tests/test_network_snapshot_fragmentation.gd` 使用实际权威移动状态量测 1、4、8、16 人的 `var_to_bytes` 大小和分片数，并验证：

- 16 人完整 tick 的所有高频片均不超过 1200 字节；
- 缺片不能被应用为完整世界；
- 新 tick 会取代不完整旧 tick，迟到旧片被拒绝；
- 完整新 tick 最终收敛到 16 个稳定玩家 ID。

`tests/test_network_scale_enet.gd` 会启动一个真实 ENet 房主、15 个真实客户端和第 17 个溢出客户端，持续采样约 5 秒，记录系统、处理器数、运行时长、移动/战斗包大小与频率，并验证：

- 16 个席位均收到完整 16 人 tick；
- 第 17 人收到 `room_full` 且没有身份；
- 16 人移动状态实际经过多个 MTU 安全片收敛；
- 可靠 combat 流产生可记录的实际载荷。

配套的既有真实 ENet 测试继续负责 30 秒保留席位、原身份重连、过期后新 ID、late join baseline、房主断开和权威 combat；既有生命周期测试覆盖 `time_limit`、`all_stars_consumed`、`no_contenders` 和结束后拒绝新身份。

## 云端执行状态

在云端工作区配置官方 Godot `4.7.2.stable.official.ed1daf0bf` 后完成验证：

- `test_network_snapshot_fragmentation.gd`：`RESULT: 0 failures`。1/4/8/16 人原始移动载荷分别为 436/1480/2872/5712 字节，分别拆成 1/2/4/8 个包；16 人各片均低于 1200 字节预算。
- `test_network_scale_enet.gd`：修复 fixture 静态类型和采样生命周期后连续运行两次，均为 `RESULT: 0 failures`。15 个远端客户端在完整五秒采样期间保持在线、均应用完整 16 人原子 tick，且最终 tick 距房主不超过 120 tick；第 17 个连接收到 `room_full` 且没有身份。
- 最新一组 `LOAD SAMPLE`：Linux，9 个处理器，elapsed 16.46 秒；snapshot 272 batches / 1957 packets / 1714024 payload bytes / 912 max packet bytes；combat 273 packets / 2718780 payload bytes / 11368 max packet bytes。15 个客户端分别应用 100–254 个完整批次，最终 tick 距房主 0–9 tick。
- `test_network_session_enet.gd`、`test_network_reconnect_enet.gd`、`test_network_reconnect_expiry_enet.gd`、`test_network_late_join.gd`、`test_network_match_lifecycle.gd`：全部 `RESULT: 0 failures`。
- combat replica、match/melee/shotgun/extraction authority，以及 extraction/melee/shotgun 真实 ENet 回归：全部 `RESULT: 0 failures`。全新检出先通过 headless editor 完成资源导入，重跑时无资源加载错误。
- `git diff --check`：通过。云端仍未配置 `gdformat` 或 `gdlint`。

## 本地运行建议

使用与项目匹配的 Godot 4.7，在仓库根目录依次运行：

```bash
godot --headless --path . --script res://tests/test_network_snapshot_fragmentation.gd
godot --headless --path . --script res://tests/test_network_scale_enet.gd
godot --headless --path . --script res://tests/test_network_session_enet.gd
godot --headless --path . --script res://tests/test_network_reconnect_enet.gd
godot --headless --path . --script res://tests/test_network_reconnect_expiry_enet.gd
godot --headless --path . --script res://tests/test_network_late_join.gd
godot --headless --path . --script res://tests/test_network_match_lifecycle.gd
```

保留 `test_network_scale_enet.gd` 输出的 `ARTIFACTS` 路径和 `LOAD SAMPLE` 行，作为机器、时长、1/4/8/16 snapshot 与 combat 载荷的本地验收证据。

## 未解决风险

- 1200 字节限制约束的是 Godot Variant RPC 参数序列化结果，不含底层 ENet、UDP/IP 和加密/平台特定封装；本地抓包应确认最终 datagram 未超过目标网络路径 MTU。
- 可靠 baseline/combat 允许 ENet 可靠分片；16 人长时间运行仍需观察丢包、队头阻塞、主机帧时间和内存，而不能只凭单次包大小判定稳定性。
- 真实 16 席测试会并行启动 17 个 Godot 子进程，应在资源足够的本地机器执行，并至少追加一次 10 分钟 soak 测试。
