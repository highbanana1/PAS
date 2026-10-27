extends RefCounted
## Pure host-owned match clock, star quota, and individual result ledger.
## MatchAuthority calls step() after extraction, movement, and combat for a tick.

const DEFAULT_DURATION_TICKS: int = 36000 # 10 minutes at 60 Hz.
const MAX_OPENING_PLAYERS: int = 16
const STATUS_ACTIVE: String = "active"
const STATUS_EXTRACTED: String = "extracted"
const STATUS_REMOVED: String = "removed"
const RESULT_WIN: String = "win"
const RESULT_LOSS: String = "loss"
const REASON_ALL_STARS: String = "all_stars_consumed"
const REASON_NO_CONTENDERS: String = "no_contenders"
const REASON_TIME_LIMIT: String = "time_limit"

var _duration_ticks: int = DEFAULT_DURATION_TICKS
var _started: bool = false
var _ended: bool = false
var _start_tick: int = -1
var _last_step_tick: int = -1
var _end_tick: int = -1
var _end_reason: String = ""
var _opening_count: int = 0
var _quota: int = 0
var _star_ids: Array[String] = []
var _participants: Dictionary = {}
var _results: Dictionary = {}
var _consumed_count: int = 0
var _revision: int = 0

## Configure before start; the default is exactly 600 seconds of authority time.
func configure(duration_ticks: int = DEFAULT_DURATION_TICKS) -> bool:
	if _started or duration_ticks <= 0:
		return false
	_duration_ticks = duration_ticks
	return true

## Freeze the opening roster and selected star supply. A map must register
## exactly these stars before this call and provide at least one usable point.
func start(opening_player_ids: Array, star_ids: Array, tick: int) -> bool:
	if _started or tick < 0 or opening_player_ids.is_empty() \
			or opening_player_ids.size() > MAX_OPENING_PLAYERS:
		return false
	var players: Array[String] = _normalized_ids(opening_player_ids)
	if players.size() != opening_player_ids.size():
		return false
	var selected_stars: Array[String] = _normalized_ids(star_ids)
	var quota: int = ceili(float(players.size()) / 4.0)
	if selected_stars.size() != star_ids.size() or selected_stars.size() != quota:
		return false
	_start_tick = tick
	_last_step_tick = tick - 1
	_opening_count = players.size()
	_quota = quota
	_star_ids = selected_stars
	for player_id: String in players:
		_participants[player_id] = STATUS_ACTIVE
	_started = true
	_revision += 1
	return true

## Late joins enter combat but never change the frozen supply or deadline.
## Player IDs are permanent match identities, even when a transport seat is reused.
func record_join(player_id: StringName) -> bool:
	var key := String(player_id)
	if not _started or _ended or key.is_empty() or _participants.has(key):
		return false
	_participants[key] = STATUS_ACTIVE
	_revision += 1
	return true

func record_extracted(player_id: StringName) -> bool:
	var key := String(player_id)
	if not _started or _ended or String(_participants.get(key, "")) != STATUS_ACTIVE:
		return false
	_participants[key] = STATUS_EXTRACTED
	_results[key] = RESULT_WIN
	_revision += 1
	return true

## Timeout cleanup removes a contender. An already extracted player's win is
## permanent even if their spectator seat later expires.
func record_removed(player_id: StringName) -> bool:
	var key := String(player_id)
	if not _started or _ended or String(_participants.get(key, "")) != STATUS_ACTIVE:
		return false
	_participants[key] = STATUS_REMOVED
	_results[key] = RESULT_LOSS
	_revision += 1
	return true

## Call once per authority tick after extraction.step() and combat. The
## extraction state must contain each frozen star and may contain its results.
## Returns true only on the transition to an ended match.
func step(tick: int, extraction_state: Dictionary) -> bool:
	if not _started or _ended or tick < _start_tick or tick <= _last_step_tick:
		return false
	var stars_variant: Variant = extraction_state.get("stars")
	if not stars_variant is Dictionary:
		return false
	var stars: Dictionary = stars_variant
	var consumed: int = 0
	for star_id: String in _star_ids:
		var raw: Variant = stars.get(star_id)
		if not raw is Dictionary:
			return false
		var phase := String((raw as Dictionary).get("state", ""))
		if phase not in ["FREE", "CARRIED", "BOUND", "CONSUMED"]:
			return false
		if phase == "CONSUMED": consumed += 1
	var results_variant: Variant = extraction_state.get("results", {})
	if not results_variant is Dictionary:
		return false
	_last_step_tick = tick
	for raw_id: Variant in (results_variant as Dictionary):
		if String((results_variant as Dictionary)[raw_id]) == "extracted":
			record_extracted(StringName(String(raw_id)))
	if consumed != _consumed_count:
		_consumed_count = consumed
		_revision += 1
	var reason := ""
	if consumed == _quota:
		reason = REASON_ALL_STARS
	elif _active_count() == 0:
		reason = REASON_NO_CONTENDERS
	elif tick >= _start_tick + _duration_ticks:
		reason = REASON_TIME_LIMIT
	if reason.is_empty(): return false
	_ended = true
	_end_tick = tick
	_end_reason = reason
	for player_id: String in _participants:
		if String(_participants[player_id]) == STATUS_ACTIVE:
			_results[player_id] = RESULT_LOSS
	_revision += 1
	return true

func get_state() -> Dictionary:
	var current_tick: int = maxi(_last_step_tick, _start_tick)
	return {
		"revision": _revision,
		"phase": "ended" if _ended else ("running" if _started else "waiting"),
		"started": _started,
		"ended": _ended,
		"start_tick": _start_tick,
		"last_step_tick": _last_step_tick,
		"duration_ticks": _duration_ticks,
		"remaining_ticks": maxi(_start_tick + _duration_ticks - current_tick, 0) if _started else _duration_ticks,
		"end_tick": _end_tick,
		"end_reason": _end_reason,
		"opening_player_count": _opening_count,
		"star_quota": _quota,
		"star_ids": _star_ids.duplicate(),
		"consumed_stars": _consumed_count,
		"active_count": _active_count(),
		"participants": _participants.duplicate(true),
		"results": _results.duplicate(true),
	}

func _active_count() -> int:
	var count: int = 0
	for status: Variant in _participants.values():
		if String(status) == STATUS_ACTIVE: count += 1
	return count

func _normalized_ids(values: Array) -> Array[String]:
	var result: Array[String] = []
	for value: Variant in values:
		if not (value is String or value is StringName): return []
		var id := String(value)
		if id.is_empty() or result.has(id): return []
		result.append(id)
	return result
