extends CanvasLayer

var _actor: Node2D
var _lifecycle: Node
@onready var countdown: Label = %Countdown


func _ready() -> void:
	# Render the 12px glyph grid at integer multiples, without smoothing.
	var pixel_font: FontFile = preload("res://asset/fonts/fusion-pixel-12px-monospaced-zh_hans.otf.woff2").duplicate()
	pixel_font.antialiasing = TextServer.FONT_ANTIALIASING_NONE
	pixel_font.hinting = TextServer.HINTING_NONE
	pixel_font.subpixel_positioning = TextServer.SUBPIXEL_POSITIONING_DISABLED
	pixel_font.oversampling = 1.0
	for label: Label in [%Title, %Countdown, %Caption]:
		label.add_theme_font_override("font", pixel_font)


func bind_player(player: Node2D) -> void:
	bind_actor(player)

func bind_actor(actor: Node2D) -> void:
	unbind_actor()
	if not is_instance_valid(actor) or actor.get("is_locally_controlled") == false or not actor.has_method("get_respawn_component"): return
	_actor = actor
	_lifecycle = actor.get_respawn_component()
	_lifecycle.died.connect(_on_character_died)
	_lifecycle.countdown_changed.connect(_update_countdown)
	_lifecycle.respawn_requested.connect(_on_respawn)
	_actor.tree_exiting.connect(unbind_actor)
	if _lifecycle.dead: _on_character_died()

func unbind_actor() -> void:
	if is_instance_valid(_lifecycle):
		if _lifecycle.died.is_connected(_on_character_died): _lifecycle.died.disconnect(_on_character_died)
		if _lifecycle.countdown_changed.is_connected(_update_countdown): _lifecycle.countdown_changed.disconnect(_update_countdown)
		if _lifecycle.respawn_requested.is_connected(_on_respawn): _lifecycle.respawn_requested.disconnect(_on_respawn)
	if is_instance_valid(_actor) and _actor.tree_exiting.is_connected(unbind_actor): _actor.tree_exiting.disconnect(unbind_actor)
	_actor = null
	_lifecycle = null
	hide()

func _on_character_died() -> void:
	_update_countdown(_lifecycle.time_left)
	show()

func _on_respawn(_position: Vector2) -> void:
	hide()

func _update_countdown(seconds_left: float) -> void:
	countdown.text = str(maxi(ceili(seconds_left), 0))
