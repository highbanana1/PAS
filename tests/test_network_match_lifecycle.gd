extends SceneTree

const MatchLifecycle = preload("res://scene/script/network/match_lifecycle.gd")
var failures: Array[String] = []

func _initialize() -> void:
	run.call_deferred()

func check(ok: bool, label: String) -> void:
	print(("PASS: " if ok else "FAIL: ") + label)
	if not ok: failures.append(label)

func ids(prefix: String, count: int) -> Array[String]:
	var result: Array[String] = []
	for index in range(count): result.append("%s%d" % [prefix, index])
	return result

func extraction(star_ids: Array, consumed: Array = [], winners: Array = []) -> Dictionary:
	var stars: Dictionary = {}
	var results: Dictionary = {}
	for star_id: String in star_ids:
		stars[star_id] = {"state": "CONSUMED" if consumed.has(star_id) else "FREE"}
	for player_id: String in winners:
		results[player_id] = "extracted"
	return {"stars": stars, "results": results}

func run() -> void:
	test_opening_quota()
	test_late_join_freeze()
	test_same_tick_extraction_before_time_limit()
	test_early_star_exhaustion_and_winner_departure()
	test_timeout_and_idempotency()
	test_all_left_but_dead_and_reserved_stay()
	test_snapshot_isolation_and_invalid_input()
	print("RESULT: ", failures.size(), " failures")
	quit(0 if failures.is_empty() else 1)

func test_opening_quota() -> void:
	for count in [1, 4, 5, 8, 16]:
		var match_state = MatchLifecycle.new()
		var quota: int = ceili(float(count) / 4.0)
		var players: Array[String] = ids("p", count)
		var star_ids: Array[String] = ids("s", quota)
		check(match_state.start(players, star_ids, 100),
			"Opening roster %d starts with %d stars" % [count, quota])
		var snapshot: Dictionary = match_state.get_state()
		check(int(snapshot.star_quota) == quota and int(snapshot.opening_player_count) == count \
			and int(snapshot.duration_ticks) == 36000 and int(snapshot.remaining_ticks) == 36000,
			"Opening quota and ten-minute clock freeze for %d players" % count)
		check(not match_state.start(players, star_ids, 101), "A running match cannot restart")
	check(not MatchLifecycle.new().start([], ["star"], 0), "Zero opening players are invalid")
	check(not MatchLifecycle.new().start(ids("p", 17), ids("s", 5), 0),
		"More than sixteen opening players are invalid")
	check(not MatchLifecycle.new().start(["a", "b", "c", "d", "e"], ["s"], 0),
		"A five-player match cannot start below its two-star quota")
	check(not MatchLifecycle.new().start(["a", "a"], ["s"], 0),
		"Duplicate opening identities are rejected")

func test_late_join_freeze() -> void:
	var match_state = MatchLifecycle.new()
	check(match_state.start(ids("p", 4), ["s0"], 10), "Four players start")
	check(match_state.record_join(&"late"), "A late player joins the active match")
	var state: Dictionary = match_state.get_state()
	check(int(state.star_quota) == 1 and int(state.opening_player_count) == 4 \
		and int(state.active_count) == 5 and int(state.remaining_ticks) == 36000,
		"Late join leaves the opening star supply and deadline unchanged")
	check(not match_state.record_join(&"late"), "One identity cannot join twice")
	check(match_state.record_removed(&"late"), "Timed-out late joiner leaves combat")
	check(not match_state.record_join(&"late"), "A vacated identity cannot be reused by a new player")
	check(String(match_state.get_state().results.get("late", "")) == "loss",
		"Removal records a permanent loss")

func test_same_tick_extraction_before_time_limit() -> void:
	var match_state = MatchLifecycle.new()
	check(match_state.configure(2), "A short clock can be configured for a test")
	check(match_state.start(ids("p", 4), ["s0"], 100), "Match starts at a nonzero authority tick")
	check(not match_state.step(101, extraction(["s0"])), "Match continues before its deadline")
	check(match_state.step(102, extraction(["s0"], ["s0"], ["p0"])),
		"A deadline-tick extraction is applied before the match ends")
	var state: Dictionary = match_state.get_state()
	check(String(state.results.get("p0", "")) == "win" \
		and String(state.results.get("p1", "")) == "loss" \
		and String(state.end_reason) == "all_stars_consumed",
		"Same-tick evacuee wins and remaining contenders lose")
	check(int(state.end_tick) == 102 and int(state.consumed_stars) == 1,
		"Ending uses the authority tick and exact consumed supply")

func test_timeout_and_idempotency() -> void:
	var match_state = MatchLifecycle.new()
	check(match_state.configure(2) and match_state.start(["p0"], ["s0"], 7),
		"One-player match starts with a short clock")
	check(not match_state.step(8, extraction(["s0"])), "Before deadline it remains active")
	check(not match_state.step(8, extraction(["s0"])), "Duplicate ticks cannot advance the match")
	check(not match_state.step(7, extraction(["s0"])), "Older ticks cannot rewind the match")
	check(match_state.step(9, extraction(["s0"])), "Deadline ends a match with a free star")
	var state: Dictionary = match_state.get_state()
	check(String(state.end_reason) == "time_limit" and String(state.results.get("p0", "")) == "loss",
		"Unextracted contender loses when ten-minute equivalent elapses")
	var revision: int = int(state.revision)
	check(not match_state.step(10, extraction(["s0"], ["s0"], ["p0"])) \
		and int(match_state.get_state().revision) == revision,
		"An ended match cannot award a delayed win or duplicate its result")
	check(not match_state.record_join(&"new") and not match_state.record_extracted(&"p0"),
		"An ended match rejects late entrants and outcome changes")

func test_early_star_exhaustion_and_winner_departure() -> void:
	var match_state = MatchLifecycle.new()
	check(match_state.start(["winner", "other"], ["s0"], 0), "Two contenders start")
	check(match_state.record_extracted(&"winner"), "One contender extracts before the deadline")
	check(not match_state.record_removed(&"winner"),
		"A later spectator disconnect cannot turn a win into a loss")
	check(match_state.step(1, extraction(["s0"], ["s0"], ["winner"])),
		"Consuming the last star ends the match before the deadline")
	var state: Dictionary = match_state.get_state()
	check(String(state.results.get("winner", "")) == "win" \
		and String(state.results.get("other", "")) == "loss" \
		and String(state.end_reason) == "all_stars_consumed",
		"The winner stays recorded while remaining contenders fail")

func test_all_left_but_dead_and_reserved_stay() -> void:
	var match_state = MatchLifecycle.new()
	check(match_state.start(["alive", "dead", "reserved"], ["s0"], 0),
		"Active, dead and reserved contenders all count at opening")
	check(match_state.record_removed(&"alive"), "An active player times out")
	check(not match_state.step(1, extraction(["s0"])),
		"Dead or disconnected but reserved contenders prevent early end")
	check(match_state.record_removed(&"dead") and match_state.record_removed(&"reserved"),
		"The final two contenders leave")
	check(match_state.step(2, extraction(["s0"])), "No contenders ends the match")
	var state: Dictionary = match_state.get_state()
	check(String(state.end_reason) == "no_contenders" and int(state.active_count) == 0 \
		and int(state.results.size()) == 3,
		"Every removed contender is failed once")

func test_snapshot_isolation_and_invalid_input() -> void:
	var match_state = MatchLifecycle.new()
	check(not match_state.configure(0), "Nonpositive clock is rejected")
	check(match_state.start(["a"], ["s"], 5), "A valid match can still start")
	check(not match_state.step(6, {"stars": {}}), "Missing frozen star rejects the snapshot")
	check(int(match_state.get_state().last_step_tick) == 4,
		"Malformed state cannot consume an authority tick")
	var snapshot: Dictionary = match_state.get_state()
	snapshot.participants["a"] = "extracted"
	snapshot.star_ids.append("intruder")
	snapshot.results["a"] = "win"
	var fresh: Dictionary = match_state.get_state()
	check(String(fresh.participants.get("a", "")) == "active" \
		and fresh.star_ids.size() == 1 and fresh.results.is_empty(),
		"Returned state is isolated from caller mutation")
	check(not match_state.record_extracted(&"unknown") and not match_state.record_removed(&"unknown"),
		"Unknown identities cannot acquire a result")
