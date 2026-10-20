extends SceneTree

## Ticket 02B2B behavior test for the client presentation seam. It drives the
## view directly (no transport) to prove:
##   * a local input produces an observable predicted position before any
##     authoritative snapshot is applied;
##   * unconfirmed inputs are replayed from the authoritative checkpoint and are
##     dropped exactly once when their sequence is acknowledged;
##   * small errors converge smoothly, while large errors are corrected inside a
##     hard bound;
##   * remote samples interpolate at a render tick behind the newest sample,
##     ignore duplicate/regressed samples and fall back safely for missing
##     samples and discontinuous states.
## The view is presentation-only; none of these calls can reach MatchAuthority.

const VIEW_PATH := "res://scene/script/network/client_motion_view.gd"
const BRIDGE_PATH := "res://scene/script/network/match_network_bridge.gd"
const MATCH_EPOCH := 717171
const LOCAL_ID := "player_2"
const REMOTE_ID := "player_1"
const OTHER_REMOTE_ID := "player_3"
const STEP := 1.0 / 60.0

class FakeMotor:
	extends Node
	var speed: float = 300.0

class FakePredictionActor:
	extends Node
	var motor := FakeMotor.new()
	var last_state: Dictionary = {}
	func _init() -> void:
		add_child(motor)
	func get_motor() -> Node:
		return motor
	func set_authority_controlled(_enabled: bool) -> void:
		pass
	func apply_replica_state(state: Dictionary) -> void:
		last_state = state.duplicate(true)

class FakeClientSession:
	extends Node
	signal snapshot_batch_received(batch: Dictionary)
	signal identity_assigned(identity: Dictionary)
	signal baseline_received(baseline: Dictionary)
	signal baseline_rejected(result: Dictionary)
	signal session_closed()
	var epoch: int = 0
	var identity: Dictionary = {}
	var sent_commands: int = 0
	func is_host() -> bool:
		return false
	func is_active() -> bool:
		return true
	func get_match_epoch() -> int:
		return epoch
	func get_local_identity() -> Dictionary:
		return identity
	func has_baseline() -> bool:
		return false
	func get_baseline() -> Dictionary:
		return {}
	func send_command(_command: Dictionary) -> int:
		sent_commands += 1
		return sent_commands

class FakeAuthority:
	extends RefCounted
	var submit_calls: int = 0
	func submit_command(_player_id: StringName, _command: Dictionary, _sequence: int = -1) -> bool:
		submit_calls += 1
		return true

var failures: Array[String] = []

func _initialize() -> void:
	_run.call_deferred()

func check(ok: bool, label: String) -> void:
	print(("PASS: " if ok else "FAIL: ") + label)
	if not ok:
		failures.append(label)

func _finish() -> void:
	print("RESULT: ", failures.size(), " failures")
	quit(0 if failures.is_empty() else 1)

func _run() -> void:
	print("TEST: client motion prediction, reconciliation and remote interpolation")
	var view_script = load(VIEW_PATH)
	check(view_script != null and view_script.can_instantiate(), "ClientMotionView exposes a loadable presentation module")
	if view_script == null or not view_script.can_instantiate():
		_finish()
		return
	_test_prediction_before_snapshot(view_script)
	_test_replay_and_ack_ordering(view_script)
	_test_small_correction_converges(view_script)
	_test_large_correction_is_bounded(view_script)
	_test_death_and_respawn_fallbacks(view_script)
	_test_action_inputs_do_not_replay_movement(view_script)
	_test_stale_unacknowledged_input_expires(view_script)
	_test_baseline_and_identity_clear_stale_prediction(view_script)
	_test_epoch_change_clears_presentation(view_script)
	_test_deferred_epoch_adopts_baseline(view_script)
	_test_deactivate_clears_presentation(view_script)
	_test_movement_speed_tracks_motor(view_script)
	_test_remote_midpoint_interpolation(view_script)
	_test_remote_insufficient_and_regressed_samples(view_script)
	_test_remote_discontinuity_fallbacks(view_script)
	_test_remote_no_extrapolation_and_lag_fallback(view_script)
	_test_remote_roster_prune(view_script)
	_test_view_source_has_no_authority_coupling()
	_test_bridge_prediction_isolated_from_authority()
	_finish()

func _make_view(view_script: Script):
	var view = view_script.new()
	view.configure(MATCH_EPOCH)
	view.set_local_player(StringName(LOCAL_ID))
	return view

func _state(player_id: String, tick: int, position: Vector2, ack_sequence: int = -1, dead: bool = false, revision: int = 1) -> Dictionary:
	return {
		"player_id": player_id,
		"tick": tick,
		"revision": revision,
		"position": position,
		"velocity": Vector2.ZERO,
		"dead": dead,
		"health": 0.0 if dead else 150.0,
		"max_health": 150.0,
		"ack_sequence": ack_sequence,
	}

func _baseline(tick: int, players: Dictionary) -> Dictionary:
	return {
		"match_epoch": MATCH_EPOCH,
		"baseline_tick": tick,
		"server_tick": tick,
		"players": players,
	}

func _batch(tick: int, players: Dictionary) -> Dictionary:
	return {
		"match_epoch": MATCH_EPOCH,
		"server_tick": tick,
		"players": players,
	}

func _prediction(view) -> Dictionary:
	return view.get_local_prediction()

func _test_prediction_before_snapshot(view_script: Script) -> void:
	var view = _make_view(view_script)
	var baseline := _baseline(100, {
		LOCAL_ID: _state(LOCAL_ID, 100, Vector2.ZERO, 0),
	})
	check(bool(view.apply_baseline(baseline)), "Prediction fixture applies a baseline")
	var before: Vector2 = view.get_render_position(StringName(LOCAL_ID))
	check(int(view.get_pending_input_count()) == 0, "Prediction starts with no pending inputs")
	check(view.record_local_input(1, {"type": "move", "direction": Vector2.RIGHT}), "Local input is recorded with its sequence")
	check(int(view.get_pending_input_count()) == 1, "Recording one input leaves one unconfirmed sequence")
	var predicted_tick := int(view.get_local_prediction().get("authoritative_tick", -1))
	view.tick(STEP)
	var after: Vector2 = view.get_render_position(StringName(LOCAL_ID))
	check(after.x > before.x + 0.5, "Local input produces an observable predicted position before the next snapshot")
	check(predicted_tick == 100 and int(view.get_local_prediction().get("authoritative_tick", -1)) == 100, "Prediction moved without any new authoritative snapshot")
	check(int(view.get_pending_input_count()) == 1, "The unconfirmed input remains pending after prediction")
	check(int(view.get_local_prediction().get("last_ack_sequence", -2)) == 0, "Prediction exposes the last acknowledged sequence")

func _test_replay_and_ack_ordering(view_script: Script) -> void:
	var view = _make_view(view_script)
	view.apply_baseline(_baseline(100, {
		LOCAL_ID: _state(LOCAL_ID, 100, Vector2.ZERO, 0),
	}))
	view.record_local_input(1, {"type": "move", "direction": Vector2.RIGHT})
	view.record_local_input(2, {"type": "move", "direction": Vector2.RIGHT})
	var before_reconcile: Dictionary = _prediction(view)
	check(int(before_reconcile.get("pending_input_count", 0)) == 2, "Two local inputs are pending before confirmation")

	var unconfirmed := _batch(103, {
		LOCAL_ID: _state(LOCAL_ID, 103, Vector2(5.0, 0.0), 0),
	})
	check(bool(view.apply_snapshot(unconfirmed)), "An authoritative snapshot is reconciled")
	var after_unconfirmed: Dictionary = _prediction(view)
	check(int(after_unconfirmed.get("pending_input_count", 0)) == 2, "Ack 0 leaves both unconfirmed inputs pending")
	var simulated: Vector2 = after_unconfirmed.get("simulated_position", Vector2.ZERO)
	check(is_equal_approx(simulated.x, 5.0 + 2.0 * 2.5), "Unconfirmed inputs are replayed from the authoritative checkpoint exactly once")

	var confirmed_one := _batch(106, {
		LOCAL_ID: _state(LOCAL_ID, 106, Vector2(10.0, 0.0), 1),
	})
	view.apply_snapshot(confirmed_one)
	var after_one: Dictionary = _prediction(view)
	check(int(after_one.get("pending_input_count", 0)) == 1, "Ack 1 drops only the confirmed input")
	check(int(after_one.get("last_ack_sequence", -2)) == 1, "Ack sequence advances with the authoritative snapshot")
	simulated = after_one.get("simulated_position", Vector2.ZERO)
	check(is_equal_approx(simulated.x, 12.5), "Only the remaining unconfirmed input is replayed")

	view.apply_snapshot(confirmed_one)
	var after_duplicate: Dictionary = _prediction(view)
	check(int(after_duplicate.get("pending_input_count", 0)) == 1, "A repeated confirmation does not drop another input")
	check((after_duplicate.get("simulated_position", Vector2.ZERO) as Vector2).is_equal_approx(simulated), "A repeated confirmation does not apply movement twice")

	var confirmed_all := _batch(109, {
		LOCAL_ID: _state(LOCAL_ID, 109, Vector2(15.0, 0.0), 2),
	})
	view.apply_snapshot(confirmed_all)
	var after_all: Dictionary = _prediction(view)
	check(int(after_all.get("pending_input_count", 0)) == 0, "Ack 2 confirms every recorded input")
	check((after_all.get("simulated_position", Vector2.ZERO) as Vector2).is_equal_approx(Vector2(15.0, 0.0)), "No confirmed input is replayed again")

func _test_small_correction_converges(view_script: Script) -> void:
	var view = _make_view(view_script)
	view.apply_baseline(_baseline(100, {
		LOCAL_ID: _state(LOCAL_ID, 100, Vector2.ZERO, 0),
	}))
	check(view.inject_prediction_error(Vector2(20.0, 0.0)), "A small presentation error can be injected without touching authority")
	view.apply_snapshot(_batch(103, {
		LOCAL_ID: _state(LOCAL_ID, 103, Vector2.ZERO, 0),
	}))
	var start_error: float = ((view.get_render_position(StringName(LOCAL_ID)) as Vector2) - Vector2.ZERO).length()
	check(start_error > 10.0, "The small error is visible at reconciliation")
	var monotonic := true
	var previous := start_error
	for index in range(120):
		view.tick(STEP)
		var current: float = ((view.get_render_position(StringName(LOCAL_ID)) as Vector2) - Vector2.ZERO).length()
		if current > previous + 0.0001:
			monotonic = false
		previous = current
	check(monotonic, "Small-error correction never moves farther from the authoritative position")
	check(previous <= 0.05, "Small-error correction converges inside a bounded time")
	var diagnostics: Dictionary = _prediction(view)
	check(int(diagnostics.get("large_correction_count", 0)) == 0, "A small error uses smooth correction, not a hard snap")

func _test_large_correction_is_bounded(view_script: Script) -> void:
	var view = _make_view(view_script)
	view.apply_baseline(_baseline(100, {
		LOCAL_ID: _state(LOCAL_ID, 100, Vector2.ZERO, 0),
	}))
	view.inject_prediction_error(Vector2(240.0, 0.0))
	view.apply_snapshot(_batch(103, {
		LOCAL_ID: _state(LOCAL_ID, 103, Vector2.ZERO, 0),
	}))
	var correction: float = ((view.get_render_position(StringName(LOCAL_ID)) as Vector2) - Vector2.ZERO).length()
	check(correction <= 0.05, "A large error is corrected within one reconciliation")
	var diagnostics: Dictionary = _prediction(view)
	check(int(diagnostics.get("large_correction_count", 0)) >= 1, "The large correction is recorded as a safe hard snap")
	check(String(diagnostics.get("last_fallback_reason", "")).contains("large_error"), "The large correction exposes its fallback reason")

func _test_death_and_respawn_fallbacks(view_script: Script) -> void:
	var view = _make_view(view_script)
	view.apply_baseline(_baseline(100, {
		LOCAL_ID: _state(LOCAL_ID, 100, Vector2.ZERO, 0),
	}))
	view.record_local_input(1, {"type": "move", "direction": Vector2.RIGHT})
	view.record_local_input(2, {"type": "move", "direction": Vector2.RIGHT})
	view.apply_snapshot(_batch(103, {
		LOCAL_ID: _state(LOCAL_ID, 103, Vector2(12.0, 0.0), 1, true),
	}))
	var dead_diagnostics: Dictionary = _prediction(view)
	check(int(dead_diagnostics.get("pending_input_count", -1)) == 0, "Death clears every stale predicted input")
	check((dead_diagnostics.get("render_position", Vector2.ONE) as Vector2).is_equal_approx(Vector2(12.0, 0.0)), "Death snaps the local presentation to the authoritative position")
	check(String(dead_diagnostics.get("last_fallback_reason", "")).contains("death"), "Death exposes a safe fallback reason")

	view.apply_snapshot(_batch(106, {
		LOCAL_ID: _state(LOCAL_ID, 106, Vector2(30.0, 0.0), 2, false),
	}))
	var alive_diagnostics: Dictionary = _prediction(view)
	check(int(alive_diagnostics.get("pending_input_count", -1)) == 0, "Respawn keeps the prediction buffer empty")
	check((alive_diagnostics.get("render_position", Vector2.ZERO) as Vector2).is_equal_approx(Vector2(30.0, 0.0)), "Respawn snaps to the new authoritative spawn")
	check(String(alive_diagnostics.get("last_fallback_reason", "")).contains("respawn"), "Respawn exposes a safe fallback reason")

func _test_remote_midpoint_interpolation(view_script: Script) -> void:
	var view = _make_view(view_script)
	view.apply_baseline(_baseline(100, {
		LOCAL_ID: _state(LOCAL_ID, 100, Vector2.ZERO, 0),
		REMOTE_ID: _state(REMOTE_ID, 100, Vector2(0.0, 0.0)),
	}))
	view.apply_snapshot(_batch(103, {
		REMOTE_ID: _state(REMOTE_ID, 103, Vector2(30.0, 0.0)),
	}))
	check(int(view.get_remote_sample_count(StringName(REMOTE_ID))) == 2, "Remote buffer keeps both authoritative samples")
	view.set_remote_render_tick(101.5)
	view.tick(0.0)
	var midpoint: Dictionary = view.get_remote_render_state(StringName(REMOTE_ID))
	check(not midpoint.is_empty(), "Remote render state is available with two samples")
	var position: Vector2 = midpoint.get("position", Vector2.ZERO)
	check(is_equal_approx(position.x, 15.0), "Remote player renders at the midpoint between two server ticks")
	check(bool(midpoint.get("interpolated", false)), "Midpoint rendering is reported as interpolation")
	check(int(view.get_remote_interpolated_frame_count(StringName(REMOTE_ID))) >= 1, "Interpolated frames are observable")

func _test_remote_insufficient_and_regressed_samples(view_script: Script) -> void:
	var view = _make_view(view_script)
	view.apply_baseline(_baseline(200, {
		LOCAL_ID: _state(LOCAL_ID, 200, Vector2.ZERO, 0),
		REMOTE_ID: _state(REMOTE_ID, 200, Vector2(40.0, 0.0)),
	}))
	check(int(view.get_remote_sample_count(StringName(REMOTE_ID))) == 1, "A single remote sample is buffered")
	view.set_remote_render_tick(500.0)
	view.tick(0.0)
	var single: Dictionary = view.get_remote_render_state(StringName(REMOTE_ID))
	check((single.get("position", Vector2.ZERO) as Vector2).is_equal_approx(Vector2(40.0, 0.0)), "With one sample the remote renderer holds the newest sample and never extrapolates")

	view.apply_snapshot(_batch(203, {
		REMOTE_ID: _state(REMOTE_ID, 203, Vector2(70.0, 0.0), -1, false, 2),
	}))
	check(int(view.get_remote_sample_count(StringName(REMOTE_ID))) == 2, "A strictly newer remote sample is appended")
	var before_duplicate := int(view.get_remote_sample_count(StringName(REMOTE_ID)))
	view.apply_snapshot(_batch(203, {
		REMOTE_ID: _state(REMOTE_ID, 203, Vector2(999.0, 0.0), -1, false, 3),
	}))
	view.apply_snapshot(_batch(202, {
		REMOTE_ID: _state(REMOTE_ID, 202, Vector2(999.0, 0.0), -1, false, 4),
	}))
	check(int(view.get_remote_sample_count(StringName(REMOTE_ID))) == before_duplicate, "Duplicate and regressed remote samples are ignored")
	check(int(view.get_remote_rejected_count(StringName(REMOTE_ID))) >= 2, "Ignored remote samples are counted")

func _test_remote_discontinuity_fallbacks(view_script: Script) -> void:
	var view = _make_view(view_script)
	view.apply_baseline(_baseline(300, {
		LOCAL_ID: _state(LOCAL_ID, 300, Vector2.ZERO, 0),
		REMOTE_ID: _state(REMOTE_ID, 300, Vector2(0.0, 0.0)),
	}))
	view.apply_snapshot(_batch(303, {
		REMOTE_ID: _state(REMOTE_ID, 303, Vector2(30.0, 0.0), -1, false, 2),
	}))
	view.apply_snapshot(_batch(306, {
		REMOTE_ID: _state(REMOTE_ID, 306, Vector2(700.0, 0.0), -1, false, 3),
	}))
	var teleported: Dictionary = view.get_remote_render_state(StringName(REMOTE_ID))
	check((teleported.get("position", Vector2.ZERO) as Vector2).is_equal_approx(Vector2(700.0, 0.0)), "A teleport snaps the remote presentation to the new sample")
	check(int(view.get_remote_sample_count(StringName(REMOTE_ID))) == 1, "A teleport clears the unusable pre-jump sample history")
	check(int(view.get_remote_snap_event_count(StringName(REMOTE_ID))) >= 1, "A teleport is recorded as a safe fallback")
	check(String(view.get_remote_fallback_reason(StringName(REMOTE_ID))).contains("teleport"), "A teleport exposes its fallback reason")

	view.apply_snapshot(_batch(309, {
		REMOTE_ID: _state(REMOTE_ID, 309, Vector2(720.0, 0.0), -1, true, 4),
	}))
	var dead: Dictionary = view.get_remote_render_state(StringName(REMOTE_ID))
	check(bool(dead.get("dead", false)), "A death discontinuity snaps to the authoritative dead state")
	check((dead.get("position", Vector2.ZERO) as Vector2).is_equal_approx(Vector2(720.0, 0.0)), "A death discontinuity snaps to the authoritative death position")
	check(int(view.get_remote_sample_count(StringName(REMOTE_ID))) == 1, "Death clears the stale remote sample history")

func _test_action_inputs_do_not_replay_movement(view_script: Script) -> void:
	var view = _make_view(view_script)
	view.apply_baseline(_baseline(100, {
		LOCAL_ID: _state(LOCAL_ID, 100, Vector2.ZERO, 0),
	}))
	check(view.record_local_input(1, {"type": "move", "direction": Vector2.RIGHT}), "A movement input is pending")
	var before_jump: Vector2 = view.get_render_position(StringName(LOCAL_ID))
	check(view.record_local_input(2, {"type": "jump"}), "An action input is tracked for acknowledgement")
	check(int(view.get_pending_input_count()) == 2, "Movement and jump envelopes are both pending")
	check(view.get_render_position(StringName(LOCAL_ID)).is_equal_approx(before_jump), "A jump envelope adds no movement step")
	view.apply_snapshot(_batch(103, {
		LOCAL_ID: _state(LOCAL_ID, 103, Vector2(5.0, 0.0), 0),
	}))
	var replayed: Dictionary = _prediction(view)
	check(is_equal_approx((replayed.get("simulated_position", Vector2.ZERO) as Vector2).x, 7.5), "Replay advances only the unconsumed movement input")
	check(int(replayed.get("pending_input_count", 0)) == 2, "Both unacknowledged envelopes remain pending")
	view.apply_snapshot(_batch(106, {
		LOCAL_ID: _state(LOCAL_ID, 106, Vector2(10.0, 0.0), 2),
	}))
	var confirmed: Dictionary = _prediction(view)
	check(int(confirmed.get("pending_input_count", 0)) == 0, "Ack 2 confirms the movement and jump envelopes together")
	check((confirmed.get("simulated_position", Vector2.ZERO) as Vector2).is_equal_approx(Vector2(10.0, 0.0)), "Confirmed action inputs are never replayed as movement")

func _test_stale_unacknowledged_input_expires(view_script: Script) -> void:
	var view = _make_view(view_script)
	view.apply_baseline(_baseline(100, {
		LOCAL_ID: _state(LOCAL_ID, 100, Vector2.ZERO, 0),
	}))
	view.record_local_input(1, {"type": "move", "direction": Vector2.RIGHT})
	view.apply_snapshot(_batch(130, {
		LOCAL_ID: _state(LOCAL_ID, 130, Vector2(30.0, 0.0), 0),
	}))
	var fresh: Dictionary = _prediction(view)
	check(int(fresh.get("pending_input_count", 0)) == 1, "An unacknowledged input is replayed while inside the age window")
	check(is_equal_approx((fresh.get("simulated_position", Vector2.ZERO) as Vector2).x, 32.5), "The unacknowledged input is replayed exactly once")
	view.apply_snapshot(_batch(161, {
		LOCAL_ID: _state(LOCAL_ID, 161, Vector2(61.0, 0.0), 0),
	}))
	var expired: Dictionary = _prediction(view)
	check(int(expired.get("pending_input_count", 0)) == 0, "A stale unacknowledged input is dropped instead of replayed forever")
	check((expired.get("simulated_position", Vector2.ZERO) as Vector2).is_equal_approx(Vector2(61.0, 0.0)), "An expired input falls back to the authoritative checkpoint")
	check(String(expired.get("last_fallback_reason", "")) == "input_expired", "An expired input exposes its bounded fallback reason")

func _test_baseline_and_identity_clear_stale_prediction(view_script: Script) -> void:
	var view = _make_view(view_script)
	view.apply_baseline(_baseline(100, {
		LOCAL_ID: _state(LOCAL_ID, 100, Vector2.ZERO, 0),
	}))
	view.record_local_input(1, {"type": "move", "direction": Vector2.RIGHT})
	view.apply_snapshot(_batch(103, {
		LOCAL_ID: _state(LOCAL_ID, 103, Vector2(5.0, 0.0), 1),
	}))
	check(int(view.get_local_prediction().get("last_ack_sequence", -1)) == 1, "The confirmed sequence advanced the local ack")
	check(bool(view.apply_baseline(_baseline(200, {
		REMOTE_ID: _state(REMOTE_ID, 200, Vector2(50.0, 0.0)),
	}))), "A complete baseline without the local player is still applied")
	check(int(view.get_pending_input_count()) == 0, "A full baseline clears every pending local sequence")
	check(not bool(view.get_local_prediction().get("ready", true)), "A baseline without the local player leaves no stale local presentation")
	check(not view.get_render_states().has(LOCAL_ID), "A baseline without the local player drops the stale local render state")

	var identity_view = _make_view(view_script)
	identity_view.apply_baseline(_baseline(100, {
		LOCAL_ID: _state(LOCAL_ID, 100, Vector2.ZERO, 5),
	}))
	check(not identity_view.record_local_input(1, {"type": "move", "direction": Vector2.RIGHT}), "An already confirmed sequence is not replayed")
	identity_view.set_local_player(StringName("player_4"))
	identity_view.apply_snapshot(_batch(103, {
		"player_4": _state("player_4", 103, Vector2(1.0, 0.0), 0),
	}))
	check(identity_view.record_local_input(1, {"type": "move", "direction": Vector2.RIGHT}), "A new local identity restarts the sequence acknowledgement window")

func _test_epoch_change_clears_presentation(view_script: Script) -> void:
	var view = _make_view(view_script)
	view.apply_baseline(_baseline(100, {
		LOCAL_ID: _state(LOCAL_ID, 100, Vector2.ZERO, 0),
		REMOTE_ID: _state(REMOTE_ID, 100, Vector2.ZERO),
	}))
	view.record_local_input(1, {"type": "move", "direction": Vector2.RIGHT})
	view.apply_snapshot(_batch(103, {
		LOCAL_ID: _state(LOCAL_ID, 103, Vector2(2.5, 0.0), 0),
		REMOTE_ID: _state(REMOTE_ID, 103, Vector2(30.0, 0.0)),
	}))
	check(int(view.get_remote_sample_count(StringName(REMOTE_ID))) == 2, "Remote history exists before the epoch probe")
	var stale := _batch(106, {
		LOCAL_ID: _state(LOCAL_ID, 106, Vector2(5.0, 0.0), 0),
		REMOTE_ID: _state(REMOTE_ID, 106, Vector2(40.0, 0.0)),
	})
	stale["match_epoch"] = MATCH_EPOCH + 1
	check(not bool(view.apply_snapshot(stale)), "A snapshot from another epoch is refused")
	var diagnostics: Dictionary = _prediction(view)
	check(int(diagnostics.get("pending_input_count", -1)) == 0, "An epoch change clears pending local inputs")
	check(int(view.get_remote_sample_count(StringName(REMOTE_ID))) == 0, "An epoch change clears every remote sample")
	check(not view.get_render_states().has(REMOTE_ID), "An epoch change drops the stale remote render state")
	check(is_equal_approx(view.get_remote_render_tick(), 0.0), "An epoch change resets the remote render clock")
	check(String(diagnostics.get("last_fallback_reason", "")) == "epoch_changed", "An epoch change exposes its cleanup reason")

func _test_deferred_epoch_adopts_baseline(view_script: Script) -> void:
	var view = view_script.new()
	view.configure(0)
	view.set_local_player(StringName(LOCAL_ID))
	check(int(view.get_match_epoch()) == 0, "A pre-identity client starts without a known match epoch")
	check(bool(view.apply_baseline(_baseline(100, {
		LOCAL_ID: _state(LOCAL_ID, 100, Vector2(4.0, 0.0), 0),
	}))), "The first authoritative baseline supplies the deferred match epoch")
	check(int(view.get_match_epoch()) == MATCH_EPOCH, "The presentation view adopts the authoritative match epoch")
	check(bool(view.get_local_prediction().get("ready", false)), "Deferred-epoch presentation becomes ready after the baseline")
	check(view.get_render_states().has(LOCAL_ID), "Deferred-epoch presentation installs the local render state")
	check(view.record_local_input(1, {"type": "move", "direction": Vector2.RIGHT}), "Prediction accepts sequences after deferred-epoch adoption")
	check(is_equal_approx(view.get_render_position(StringName(LOCAL_ID)).x, 6.5), "Deferred-epoch prediction advances from the authoritative checkpoint")

func _test_deactivate_clears_presentation(view_script: Script) -> void:
	var view = _make_view(view_script)
	view.apply_baseline(_baseline(100, {
		LOCAL_ID: _state(LOCAL_ID, 100, Vector2.ZERO, 0),
		REMOTE_ID: _state(REMOTE_ID, 100, Vector2.ZERO),
	}))
	view.record_local_input(1, {"type": "move", "direction": Vector2.RIGHT})
	view.tick(STEP)
	check(view.get_render_states().size() == 2, "Prediction and remote interpolation are both rendering before close")
	view.deactivate("session_closed")
	check(not view.is_active(), "A closed session deactivates the presentation view")
	check(view.get_render_states().is_empty(), "A closed session drops every presentation render state")
	check(int(view.get_pending_input_count()) == 0, "A closed session drops pending predicted inputs")
	check(not bool(view.get_local_prediction().get("ready", true)), "A closed session marks local prediction unready")
	check(int(view.get_remote_sample_count(StringName(REMOTE_ID))) == 0, "A closed session drops remote samples")
	check(String(view.get_local_prediction().get("last_fallback_reason", "")) == "session_closed", "A closed session exposes its cleanup reason")
	view.tick(STEP)
	check(view.get_render_position(StringName(LOCAL_ID)).is_equal_approx(Vector2.ZERO), "A closed session stops rendering a frozen predicted pose")

func _test_movement_speed_tracks_motor(view_script: Script) -> void:
	var view = _make_view(view_script)
	view.apply_baseline(_baseline(100, {
		LOCAL_ID: _state(LOCAL_ID, 100, Vector2.ZERO, 0),
	}))
	check(view.set_movement_speed(300.0), "Prediction speed can adopt the bound actor motor speed")
	check(is_equal_approx(view.get_movement_speed(), 300.0), "The view reports the adopted motor speed")
	check(not view.set_movement_speed(0.0), "An invalid motor speed is rejected")
	check(is_equal_approx(view.get_movement_speed(), 300.0), "A rejected speed leaves the previous speed intact")
	view.record_local_input(1, {"type": "move", "direction": Vector2.RIGHT})
	check(is_equal_approx(view.get_render_position(StringName(LOCAL_ID)).x, 5.0), "The immediate prediction step scales with the motor speed")
	view.tick(STEP)
	check(is_equal_approx(view.get_render_position(StringName(LOCAL_ID)).x, 5.0), "The immediate step is reconciled against the fixed-step accumulator")

func _test_remote_no_extrapolation_and_lag_fallback(view_script: Script) -> void:
	var view = _make_view(view_script)
	view.apply_baseline(_baseline(100, {
		LOCAL_ID: _state(LOCAL_ID, 100, Vector2.ZERO, 0),
		REMOTE_ID: _state(REMOTE_ID, 100, Vector2.ZERO),
	}))
	view.apply_snapshot(_batch(103, {
		REMOTE_ID: _state(REMOTE_ID, 103, Vector2(30.0, 0.0)),
	}))
	view.set_remote_render_tick(1000.0)
	view.tick(0.0)
	var far: Dictionary = view.get_remote_render_state(StringName(REMOTE_ID))
	check((far.get("position", Vector2.ZERO) as Vector2).is_equal_approx(Vector2(30.0, 0.0)), "A render clock past the newest sample holds the newest sample")
	check(not bool(far.get("interpolated", true)), "No frame beyond the newest sample is reported as interpolation")
	view.set_remote_render_tick(0.0)
	view.tick(1.0)
	check(is_equal_approx(view.get_remote_render_tick(), 97.0), "An excessive lag resets the render clock to a bounded delay")
	check(String(view.get_remote_fallback_reason(StringName(REMOTE_ID))) == "remote_lag", "A lag reset is reported per remote player")
	var lagged: Dictionary = view.get_remote_render_state(StringName(REMOTE_ID))
	check((lagged.get("position", Vector2.ZERO) as Vector2).is_equal_approx(Vector2.ZERO), "A lag reset clamps to a buffered sample instead of extrapolating")

func _test_remote_roster_prune(view_script: Script) -> void:
	var view = _make_view(view_script)
	view.apply_baseline(_baseline(100, {
		LOCAL_ID: _state(LOCAL_ID, 100, Vector2.ZERO, 0),
		REMOTE_ID: _state(REMOTE_ID, 100, Vector2(10.0, 0.0)),
		OTHER_REMOTE_ID: _state(OTHER_REMOTE_ID, 100, Vector2(20.0, 0.0)),
	}))
	check(int(view.get_remote_sample_count(StringName(OTHER_REMOTE_ID))) == 1, "A third player starts with one remote sample")
	view.apply_snapshot(_batch(103, {
		LOCAL_ID: _state(LOCAL_ID, 103, Vector2.ZERO, 0),
		REMOTE_ID: _state(REMOTE_ID, 103, Vector2(40.0, 0.0)),
	}))
	check(int(view.get_remote_sample_count(StringName(REMOTE_ID))) == 2, "A present remote keeps its ordered history")
	check(int(view.get_remote_sample_count(StringName(OTHER_REMOTE_ID))) == 0, "A remote absent from the roster snapshot is pruned")
	check(not view.get_render_states().has(OTHER_REMOTE_ID), "A departed remote leaves no stale render state")
	view.apply_snapshot(_batch(106, {
		LOCAL_ID: _state(LOCAL_ID, 106, Vector2.ZERO, 0),
		OTHER_REMOTE_ID: _state(OTHER_REMOTE_ID, 106, Vector2(25.0, 0.0)),
	}))
	check(int(view.get_remote_sample_count(StringName(REMOTE_ID))) == 0, "The other departed remote is pruned in turn")
	check(int(view.get_remote_sample_count(StringName(OTHER_REMOTE_ID))) == 1, "A reappearing remote restarts from one fresh sample")
	check((view.get_remote_render_state(StringName(OTHER_REMOTE_ID)).get("position", Vector2.ZERO) as Vector2).is_equal_approx(Vector2(25.0, 0.0)), "A reappearing remote snaps to its fresh authoritative sample")

func _test_view_source_has_no_authority_coupling() -> void:
	var source := FileAccess.get_file_as_string(VIEW_PATH)
	check(not source.is_empty(), "The presentation source is readable for the authority-boundary check")
	check(not source.contains("MatchAuthorityScript"), "ClientMotionView cannot instantiate a MatchAuthority")
	check(not source.contains("submit_command("), "ClientMotionView cannot submit a gameplay command")
	check(not source.contains("get_authority("), "ClientMotionView cannot reach an authority instance")

func _test_bridge_prediction_isolated_from_authority() -> void:
	var bridge_script = load(BRIDGE_PATH)
	if bridge_script == null or not bridge_script.can_instantiate():
		check(false, "MatchNetworkBridge is loadable for the isolation test")
		return
	var session = FakeClientSession.new()
	session.epoch = MATCH_EPOCH
	session.identity = {"player_id": LOCAL_ID, "match_epoch": MATCH_EPOCH}
	var fake_authority = FakeAuthority.new()
	var bridge = bridge_script.new()
	check(bool(bridge.configure(session, fake_authority)), "Client bridge configures from the session seam")
	check(bridge.get_authority() == null, "Client bridge holds no MatchAuthority instance")
	check(not bool(bridge.is_host_authority()), "Client bridge is not a host authority")
	var actor = FakePredictionActor.new()
	check(bool(bridge.bind_actor(StringName(LOCAL_ID), actor, true)), "Client bridge binds a real-actor presentation seam")
	var movement_speed := float(bridge.get_client_prediction().get("movement_speed", 0.0))
	check(is_equal_approx(movement_speed, 300.0), "Prediction speed is read from the bound actor's CharacterMotor")
	var applied: Dictionary = bridge.apply_baseline(_baseline(100, {
		LOCAL_ID: _state(LOCAL_ID, 100, Vector2.ZERO, 0),
	}))
	check(bool(applied.get("applied", false)), "Client bridge applies the baseline before prediction")
	var before: Vector2 = bridge.get_render_position(StringName(LOCAL_ID))
	var sequence: int = bridge.submit_move(Vector2.RIGHT)
	check(sequence > 0, "A client move uses the NetworkSession envelope sequence")
	check(int(bridge.get_pending_input_count()) == 1, "The submitted move stays pending authoritative acknowledgement")
	var after: Vector2 = bridge.get_render_position(StringName(LOCAL_ID))
	check(is_equal_approx(after.x - before.x, 5.0), "Prediction steps at the real motor speed (300 px/s at 60 Hz)")
	bridge.client_view.tick(STEP)
	var after_tick: Vector2 = bridge.get_render_position(StringName(LOCAL_ID))
	check(after_tick.is_equal_approx(after), "The immediate step is charged against the next fixed simulation step")
	check(fake_authority.submit_calls == 0, "Presentation prediction never submits to an authority instance")
	check(int(session.sent_commands) == 1, "The input crossed the session transport exactly once")
	bridge.free()
	actor.free()
	session.free()
