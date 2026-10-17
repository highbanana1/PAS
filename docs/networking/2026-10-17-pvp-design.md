# PAS PvP 撤离联机设计记录

状态：设计访谈中；不是已批准规格，不包含联机实现。
日期：2026-10-17。

## 基线与已确认事项

- 用户目标：玩家对战中的个人撤离玩法，最多 16 人，重点考虑公平与命中判定。
- 稳定版本：5dfbc472e4fbcdd5b9cbc006e9f44f0061c9c37c，已正常推送 origin/develop；29 组现有回归测试通过。
- master 保持 5234fb23df615b72d12b0021d4868b155f56436e。
- 后续设计文档位于 refactor/reusable-components；不随本次设计更新 develop 的稳定基线。
- 用户授权：必要项目代码片段与简报可发送给 DeepSeek；本次要求其他模型协作节省 Codex token。原始协作简报、会话、日志和结果只保留在本机工作目录，不进入仓库。
- 用户选择 Matt Pocock 技能流程；当前使用 grill-with-docs，并加载其 grilling、domain-modeling 依赖。代码事实由模型查验，产品选择由用户确认；未确认事项不写成既定规格。

## 已确认的玩法与范围

1. 房主建房，由房主兼任权威服务器；用户接受房主优势。客户端只提交操作请求，不自行决定伤害、归属或胜利。
2. 最多 16 人；这是设计上限，尚未做网络承载测试。
3. 不采用队伍积分或击杀积分作为胜利核心。玩家个人满足条件后撤离，撤离成功算本局个人胜利。
4. 场上同时存在多颗星星，星星全场数量有限，具体初始数量尚未确定。
5. 每位玩家携带 1 颗星星即可取得撤离资格，不要求个人收集多颗。
6. 保留交付表现：玩家将星星交到桌子，星星绑定交付者，读秒完成后判定该交付者撤离成功。
7. 一位玩家成功后，其他玩家继续本局；成功者退出战斗、进入观战，不再干扰战局。
8. 房主退出则结束房间，其他玩家返回大厅；首版不做自动房主迁移。
9. 首版 PC，本机双开和局域网/IP 验证。公网匹配、房间发现、中继尚未纳入首版已确认范围。

## 第四轮待确认

12. 撤离读秒时长，以及离开、死亡、受伤如何打断。
13. 撤离取消后，已交付星星的回归位置与拾取资格。
14. 一个撤离点是否允许多人各自交星、并行读秒。
15. 撤离成功后的星星是否消耗且本局不补充。
16. 死亡是否保留现有读秒复活，还是本局淘汰。

推荐答案不等于用户选择。星星初始数量、撤离点数量、比赛结束条件、迟到/断线/重连、延迟下格挡与命中规则仍待后续讨论；有依赖的事项在前置选择明确后提问。

## 已核查的代码事实

| 主题 | 当前事实 | 设计意义 |
| --- | --- | --- |
| 移动 | Player._physics_process 对非本地角色直接返回；CharacterMotor 有显式 request_jump、request_dash、tick | is_locally_controlled 不能同时承担服务器模拟权限与本地输入权限，需分开 |
| 弹丸 | bullet.tscn Area2D 的 collision_mask 为 27，包含玩家第 2 层；Bullet 通过 CombatReceiver.deliver 处理命中 | 不是简单增加玩家碰撞掩码就能完成 PvP，仍缺可信裁决 |
| 剑 | 查询层为 2 \| 8，接受 player 与 enemy 分组，单次挥砍用本机实例 ID 防重复 | 已能查询玩家；网络事件需独立实体 ID 与挥砍 ID |
| 受伤 | CombatReceiver.receive_attack 直接结算有效伤害；Player.hit_cooldown 的 Timer 针对接触伤害流程 | Inspector 的 1 秒无敌不能被误写为全部武器伤害均无敌 |
| 生命格 | HealthComponent.apply_damage 将一次伤害限制到当前格剩余血量 | 联网不应未经批准改变吞超额规则；多弹丸合并会改变既有语义 |
| 物品 | Inventory 持有 ItemData RefCounted，holder 为 WeakRef，icon 为 Texture2D | 网络应传物品类型与数值状态及实体 ID，不能直接复制引用 |
| 星星 | 携带状态持有 Node 引用，释放冷却记录使用实例 ID 与 WeakRef | 归属、死亡释放、交付要在权威方结算，视觉跟随可本地表现 |
| 桌上得分 | 当前 DeliveryReceiver 只接收并持有星星；win_countdown 仅是未使用的字段，没有得分读秒结算 | 读秒、计分和桌上争夺属于新增规则，不能假称已有 |
| 上膛 | 每枪 ShotCycle 独立计时，0.65 秒间隔，切枪保留冷却，复活重置 | 客户端上膛表现不应成为服务器认可下一次开火的依据 |

更多证据正在由只读辅助审查补充。上表是当前源码事实；未声称已有网络权限、命中补偿或反作弊实现。

## 文档核验来源

- [Godot 高层联机：RPC、发送者与通道](https://docs.godotengine.org/en/stable/tutorials/networking/high_level_multiplayer.html)。
- [MultiplayerSynchronizer：对象、Resource、实例 ID 不适合直接同步](https://docs.godotengine.org/en/stable/classes/class_multiplayersynchronizer.html)。
- [MultiplayerSpawner：权威方生成与销毁](https://docs.godotengine.org/en/stable/classes/class_multiplayerspawner.html)。
- [ENetMultiplayerPeer](https://docs.godotengine.org/en/stable/classes/class_enetmultiplayerpeer.html)。

官方文档只证明工具行为，不代替本项目玩法选择。Godot 安装版本在稳定基线中为 4.7.2；实现前需针对实际运行版本验证。

## 工程风险与协作核验状态

- 弹丸显示与碰撞范围需要专门讨论：当前 bullet.tscn 胶囊 radius=6、height=52，而可见弹丸约 4.93 世界像素。稳定版暂不改动；PvP 是否调整须单独确认，不能以“网络重构”名义悄悄改数值。
- 弹丸在 _process 移动并通过 Area2D 信号结算，没有权威扫掠逻辑；屏幕退出负责销毁。房主摄像机不能决定远端战斗中的弹丸寿命，应将权威寿命/边界与本地可见性分离。尚未测试具体高速漏碰撞或无界面行为。
- 当前桌子只接受一个目标且交付后锁定，没有个人撤离计时/绑定/观战结算；这些是新增规则，不是假定已实现。
- DeepSeek Pro 的计划讨论调用完成，提供了风险分析和后续问题树；Codex 已逐项核对采用部分事实。其“不保证保持数值”等泛化意见不是用户决策，未采纳为规则。
- DeepSeek Harness 的全范围只读审查在 300 秒超时，未产生完成报告；不计作通过审查，也不自动重跑。后续辅助委托将缩小到明确的独立单元。
- 29 组测试仅验证现有单机基线，不证明任何联机延迟、公平性或 16 人性能指标。
