extends Area2D

# 拾取后悬浮在玩家 Y -10
@export var float_offset_y: float = -30

# 状态
var is_picked: bool = false
var ref = null

func _ready() -> void:
	# 开局固定出生位置
	global_position = Vector2(100, -100)
	# 绑定玩家触碰信号
	body_entered.connect(_on_player_touch)

func _process(delta: float) -> void:
	# 已拾取则跟随玩家悬浮
	if is_picked and ref != null:
		global_position.x = ref.global_position.x
		global_position.y = ref.global_position.y + float_offset_y
		# 轻微上下浮动星光效果（修复计时函数）
		global_position.y += sin(Time.get_ticks_msec() * 0.003) * 2.5

func _on_player_touch(body: Node2D) -> void:
	# 防止重复拾取
	if is_picked:
		return
	# 只识别玩家（你的玩家根节点是CharacterBody2D）
	if body.is_in_group("player"):
		is_picked = true
		ref = body
		body.current_winning_point = $"."
		# 拾取后关闭碰撞，避免重复触发
		#monitoring = false
