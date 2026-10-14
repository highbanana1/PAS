extends CanvasLayer

var _player: Player
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


func bind_player(player: Player) -> void:
	if is_instance_valid(_player):
		_player.character_died.disconnect(_on_character_died)
		_player.respawned.disconnect(hide)
		_player.respawn_countdown_changed.disconnect(_update_countdown)
	_player = null
	hide()
	if not is_instance_valid(player) or not player.is_locally_controlled:
		return
	_player = player
	_player.character_died.connect(_on_character_died)
	_player.respawned.connect(hide)
	_player.respawn_countdown_changed.connect(_update_countdown)
	if _player.is_dead:
		_on_character_died()


func _on_character_died() -> void:
	_update_countdown(_player.respawn_time_left)
	show()


func _update_countdown(seconds_left: float) -> void:
	countdown.text = str(maxi(ceili(seconds_left), 0))
