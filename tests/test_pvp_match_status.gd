extends SceneTree

const PvPMain = preload("res://scene/script/pvp_main.gd")
var failures: Array[String] = []

func _initialize() -> void:
	run.call_deferred()

func check(ok: bool, label: String) -> void:
	print(("PASS: " if ok else "FAIL: ") + label)
	if not ok: failures.append(label)

func run() -> void:
	var pvp := PvPMain.new()
	check("剩余 30 秒" in pvp._match_status_text({"phase": "running",
		"remaining_ticks": 1800, "results": {}}, "p1"), "Running HUD shows authority time")
	check("观战中" in pvp._match_status_text({"phase": "running",
		"results": {"p1": "win"}}, "p1"), "Extracted player sees spectator status")
	check("胜利" in pvp._match_status_text({"phase": "ended",
		"results": {"p1": "win"}, "end_reason": "time_limit"}, "p1"),
		"Winner sees personal result at time limit")
	check("星星已耗尽" in pvp._match_status_text({"phase": "ended",
		"results": {"p1": "loss"}, "end_reason": "all_stars_consumed"}, "p1"),
		"Loser sees authoritative end reason")
	var removed_actor := Node2D.new()
	pvp._actors["p2"] = removed_actor
	removed_actor.queue_free()
	check(not pvp._can_spectate("p2", "p1"), "Queued actor cannot become spectator target")
	pvp.free()
	print("RESULT: ", failures.size(), " failures")
	quit(0 if failures.is_empty() else 1)
