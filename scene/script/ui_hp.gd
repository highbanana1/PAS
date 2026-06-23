extends CanvasLayer

# 绑定三根分段血条
@export var bar1: TextureProgressBar
@export var bar2: TextureProgressBar
@export var bar3: TextureProgressBar
# 单段血量上限
@export var single_bar_hp: float = 30.0
# 玩家节点引用
@export var player: CharacterBody2D

func _ready() -> void:
	# 绑定玩家血量变化信号，和示例截图逻辑完全一致
	player.health_changed.connect(update_three_bars)
	# 初始化三根条最大数值
	bar1.max_value = single_bar_hp
	bar2.max_value = single_bar_hp
	bar3.max_value = single_bar_hp
	# 初始化一次显示
	update_three_bars()

# 核心更新函数（对应截图里的update_health）
func update_three_bars() -> void:
	var total_max = single_bar_hp * 3
	var current_hp = player.real_hp
	var val = clamp(current_hp, 0, total_max)
	
	# 分段计算三段进度
	var seg3 = clamp(val - single_bar_hp * 2, 0, single_bar_hp)
	var seg2 = clamp(val - single_bar_hp, 0, single_bar_hp)
	var seg1 = clamp(val, 0, single_bar_hp)
	
	# 赋值给三根血条
	bar3.value = seg3
	bar2.value = seg2
	bar1.value = seg1
