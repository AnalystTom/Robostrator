#!/usr/bin/env bash
# Behavior tests for the supervision host loop (stub engine, both postures, wakes, closes, mirror, return)
# (bin/fm-supervision-host.sh, docs/supervision-host.md). Shared fixtures live
# in tests/supervision-host-helpers.sh.
#
# The loop cases run the real host, arm, watcher, wake grant, drain, outcome
# store, and lease scripts in a fixture home. The host runs as a child of a fake
# harness (a bash symlink named "claude") whose pid is the home's session lock,
# and its engine is a stub named by FM_SUPERVISION_ENGINE_CLAUDE_BIN that does
# what a branch turn does through the same scripts, so the real argument
# construction, bounding, and reaping are exercised without a model. A real
# status append drives each wake through the real watcher.
# shellcheck disable=SC2016 # single-quoted scripts expand inside their own shells
set -u

# shellcheck source=tests/supervision-host-helpers.sh
. "$(dirname "${BASH_SOURCE[0]}")/supervision-host-helpers.sh"

test_park_exit_probe_uses_half_second_child_sleeps() {
  local home host_pid
  home=$(make_home park-cadence attended)
  cat > "$home/fakebin/sleep" <<'SH'
#!/bin/bash
pid=''
if [ -f "$FM_HOME/probe-host" ]; then
  IFS= read -r pid < "$FM_HOME/probe-host" || true
  if [ "$PPID" = "$pid" ]; then
    printf '%s\n' "$1" >> "$FM_HOME/park-sleeps"
  fi
fi
exec /bin/sleep "$@"
SH
  chmod +x "$home/fakebin/sleep"
  start_host "$home"
  wait_until 150 watcher_live "$home" || fail "park-cadence: no watcher started"
  host_pid=$(awk -F '\t' '$1 == "host" { print $2; exit }' "$home/state/.supervision-host")
  [ -n "$host_pid" ] || fail "park-cadence: no recorded host"
  printf '%s\n' "$host_pid" > "$home/probe-host"
  wait_until 100 test -s "$home/park-sleeps" || fail "park-cadence: no child sleep observed"
  [ "$(sort -u "$home/park-sleeps")" = 0.5 ] || fail "park-cadence: exit probing did not use half-second sleeps"
  stop_home_processes "$home"
  pass "host: parked child-exit sampling uses ordinary half-second sleeps"
}

test_attended_routine_wake_is_handled_on_the_engine_and_stays_off_main() {
  local home first drained
  home=$(make_home attended-routine attended)
  start_host "$home"
  wait_until 150 watcher_live "$home" || fail "attended: the host never started a watcher cycle: $(cat "$home/host.out")"
  append_status "$home" 'step one'
  wait_until 250 handled_at_least "$home" 1 \
    || fail "attended: the wake was not handled on the engine: $(cat "$home/host.out"; cat "$home/state/.supervision-host.log")"
  first="$home/engine-call.1"
  assert_re '^actor=branch$' "$first" "the attended engine must run as the branch actor"
  assert_no_re '^POSTURE: AWAY' "$first" "an attended wake must carry no away tail"
  assert_re '^(arg=)?FIRSTMATE SUPERVISION WAKE: signal: ' "$first" "the attended wake must carry the close"
  assert_re '	handled	turn=[^	]*	posture=attended	' "$home/state/.supervision-host.log" "the ledger must record the attended turn"
  assert_grep '"verdict":"routine"' "$home/state/branch-outcomes.jsonl" "the engine's routine report did not reach the store"
  assert_no_grep 'demo.status' "$home/state/.wake-queue" "the engine's acknowledgement did not consume the wake"
  assert_no_grep 'supervision-host-return' "$home/state/.wake-queue" "an attended report must queue no return wake for main"
  assert_grep 'it waits in the outcome store for MAIN' "$home/engine-report.log" "an attended routine report must say it stays in the store"
  [ ! -s "$home/host.rc" ] || fail "a routine attended outcome reached main: $(cat "$home/host.out")"
  [ "$(grep -cv '^watcher: started pid=' "$home/host.out")" -eq 0 ] \
    || fail "a routine attended outcome printed more than the first cycle's status to main: $(cat "$home/host.out")"
  watcher_live "$home" || fail "the host is not parked on a live successor after an attended wake"
  drained=$(FM_HOME="$home" "$FAKE_CLAUDE" -c '"$0" 2>&1' "$ROOT/bin/fm-wake-drain.sh")
  assert_contains "$drained" "BRANCH OUTCOMES, ROUTINE (handled by the supervision session since your last drain" \
    "main's next drain must list the routine outcome for awareness"
  assert_contains "$drained" "[seq 1] demo: stub handled demo" "the routine listing must carry the outcome"
  assert_not_contains "$drained" "mark-processed" "a routine outcome must ask for no acknowledgement"
  drained=$(FM_HOME="$home" "$FAKE_CLAUDE" -c '"$0" 2>&1' "$ROOT/bin/fm-wake-drain.sh")
  assert_not_contains "$drained" "[seq 1]" "a routine outcome must be listed only once"
  pass "host: an attended wake the branch may take is handled on the engine, and its routine outcome never wakes main"
}


# A TERM that lands just after a handled wake, while the host settles its
# successor handoff under the queue and marker locks, must not leave the host
# waiting in its own exit cleanup on the queue lock it still holds: that wedged
# the host (and every later queue append) instead of exiting.

test_host_stopped_right_after_a_handled_wake_exits_and_frees_the_queue() {
  local home pid
  home=$(make_home handled-then-term attended)
  echo hold-marker > "$home/stub-mode"
  start_host "$home"
  wait_until 150 watcher_live "$home" || fail "handled then TERM: the host never started a watcher cycle"
  append_status "$home" 'step one'
  wait_until 250 handled_at_least "$home" 1 \
    || fail "handled then TERM: the wake was not handled on the engine: $(cat "$home/state/.supervision-host.log")"
  pid=$(awk -F '\t' '$1 == "host" { print $2; exit }' "$home/state/.supervision-host")
  [ -n "$pid" ] || fail "fixture: no host record after the handled wake"
  kill -TERM "$pid" 2>/dev/null || true
  wait_until 100 bash -c '! kill -0 "$1" 2>/dev/null' _ "$pid" \
    || fail "handled then TERM: the host did not exit within 10s of TERM after a handled wake"
  FM_HOME="$home" timeout 10 bash -c '. "$1"; fm_wake_append check probe "check: probe"' _ "$ROOT/bin/fm-wake-lib.sh" \
    || fail "handled then TERM: the stopped host left the wake queue lock held"
  stop_home_processes "$home"
  pass "host: a host stopped right after a handled wake exits and leaves the wake queue usable"
}


# A wrapper may launch the engine in another time zone than the host's (one
# observed wrapper exports a TZ the main session's hooks never see). The
# process-table identity that ties the branch grant to the host must read the
# same from both, or the engine's drain discards the grant as stale, refuses,
# and leaves every granted row for main. The proc root is hidden so Linux takes
# the same process-table path as macOS.

test_engine_in_another_time_zone_handles_its_granted_rows() {
  local home no_proc
  home=$(make_home engine-tz attended)
  no_proc="$TMP_ROOT/engine-tz-no-proc"
  [ "$(TZ=UTC0 LC_ALL=C ps -p $$ -o lstart=)" != "$(TZ=ENG-9 LC_ALL=C ps -p $$ -o lstart=)" ] \
    || fail "fixture: ps renders the same start time in both time zones, so the case would prove nothing"
  printf 'ENG-9\n' > "$home/stub-tz"
  TZ=UTC0 FM_PROC_ROOT_OVERRIDE="$no_proc" start_host "$home"
  wait_until 150 watcher_live "$home" || fail "engine tz: the host never started a watcher cycle: $(cat "$home/host.out")"
  append_status "$home" 'step one'
  wait_until 250 handled_at_least "$home" 1 \
    || fail "engine tz: the turn did not end handled: $(cat "$home/state/.supervision-host.log"; cat "$home"/engine-drain.* 2>/dev/null)"
  assert_no_re '	failed	' "$home/state/.supervision-host.log" "engine tz: a turn that reported for its granted rows must not fail"
  assert_no_grep 'no branch-eligible row snapshot' "$home/engine-drain.1" "engine tz: the engine's drain discarded the host's grant"
  assert_no_grep 'demo.status' "$home/state/.wake-queue" "engine tz: the engine's acknowledgement did not consume the wake"
  [ ! -s "$home/host.rc" ] || fail "engine tz: the handled wake reached main: $(cat "$home/host.out")"
  pass "host: an engine in another time zone than the host drains, reports, and acknowledges its granted rows"
}

test_attended_captain_outcome_reaches_main_through_branch_outcomes() {
  local home drained
  home=$(make_home attended-captain attended)
  echo captain > "$home/stub-mode"
  start_host "$home"
  wait_until 150 watcher_live "$home" || fail "captain: the host never started a watcher cycle"
  append_status "$home" 'ready for review'
  wait_until_deadline 60 host_exited "$home" || fail "captain: the captain outcome did not wake main: $(cat "$home/state/.supervision-host.log")"
  expect_code 0 "$(cat "$home/host.rc")" "a captain-outcome exit must exit 0 for the owner to deliver"
  assert_re '^supervision-host: branch-outcome: .*\(store rows 1\); run bin/fm-wake-drain.sh' "$home/host.out" \
    "the exit must name the captain outcome's store row and send main to its drain"
  assert_no_re '^signal:' "$home/host.out" "the close the engine handled must not reach main as a wake"
  assert_grep 'MAIN processes it from its next drain' "$home/engine-report.log" "an attended captain report must say main processes it"
  assert_no_grep 'demo.status' "$home/state/.wake-queue" "the handled wake must stay acknowledged"
  assert_no_grep 'supervision-host-return' "$home/state/.wake-queue" "an attended captain report must queue no return wake"
  watcher_live "$home" && fail "the host left its successor cycle running when it woke main"

  drained=$(FM_HOME="$home" "$FAKE_CLAUDE" -c '"$0" 2>&1' "$ROOT/bin/fm-wake-drain.sh")
  assert_contains "$drained" "BRANCH OUTCOMES (captain outcomes the supervision session recorded for you" "main's drain must present the captain outcome"
  assert_contains "$drained" "[seq 1, recorded " "the section must carry the outcome's row and when it was recorded"
  assert_contains "$drained" " ago] demo: stub escalated: " "the section must carry the outcome's task and summary"
  assert_contains "$drained" "run bin/fm-branch-outcome.sh mark-processed --through 1" "the section must print its exact acknowledgement"
  drained=$(FM_HOME="$home" "$FAKE_CLAUDE" -c '"$0" 2>&1' "$ROOT/bin/fm-wake-drain.sh")
  assert_contains "$drained" " ago] demo: stub escalated: " "an unacknowledged captain outcome must be presented again"
  FM_HOME="$home" "$ROOT/bin/fm-branch-outcome.sh" mark-processed --through 1 >/dev/null \
    || fail "main's acknowledgement of the presented outcome was refused"
  drained=$(FM_HOME="$home" "$FAKE_CLAUDE" -c '"$0" 2>&1' "$ROOT/bin/fm-wake-drain.sh")
  assert_not_contains "$drained" "BRANCH OUTCOMES" "an acknowledged captain outcome must not be presented again"
  pass "host: an attended captain outcome wakes main once and stays in its drain until main acknowledges it"
}

test_captain_leaving_mid_turn_keeps_its_captain_outcome_for_the_return() {
  local home drained
  home=$(make_home attended-go-away attended)
  echo go-away > "$home/stub-mode"
  start_host "$home"
  wait_until 150 watcher_live "$home" || fail "go-away: the host never started a watcher cycle"
  append_status "$home" 'finished while the captain left'
  wait_until 250 handled_at_least "$home" 1 || fail "go-away: the wake was not handled: $(cat "$home/state/.supervision-host.log")"
  [ -f "$home/state/.afk-contract" ] || fail "fixture: the stub did not record the away posture"
  [ ! -s "$home/host.rc" ] || fail "a captain outcome recorded after the captain left woke main: $(cat "$home/host.out")"
  assert_grep '"verdict":"captain"' "$home/state/branch-outcomes.jsonl" "fixture: the stub did not report a captain outcome"
  drained=$(FM_HOME="$home" "$FAKE_CLAUDE" -c '"$0" 2>&1' "$ROOT/bin/fm-wake-drain.sh")
  assert_not_contains "$drained" "BRANCH OUTCOMES" "captain outcomes must wait for the return while the away record exists"
  FM_HOME="$home" "$CONTRACT" archive >/dev/null 2>&1 || fail "fixture: could not archive the away posture"
  drained=$(FM_HOME="$home" "$FAKE_CLAUDE" -c '"$0" 2>&1' "$ROOT/bin/fm-wake-drain.sh")
  assert_contains "$drained" " ago] demo: stub handled demo" "after the return the drain must present the away window's captain outcome"
  pass "host: a captain outcome recorded after the captain left waits for the return, then reaches main's drain"
}


# A quiet record left without its daemon (no state/.afk) is a present captain,
# not an away one: the host runs attended beside it, so a captain outcome wakes
# main and reaches its drain instead of waiting for a return that never comes,
# and a decision close reaches main as the plain arm delivers it.

test_quiet_record_without_its_daemon_is_a_present_captain() {
  local home drained
  home=$(make_home quiet-captain quiet)
  echo captain > "$home/stub-mode"
  start_host "$home"
  wait_until 150 watcher_live "$home" || fail "quiet: the host never started a watcher cycle"
  append_status "$home" 'ready for review'
  wait_until_deadline 60 host_exited "$home" || fail "quiet: the captain outcome did not wake the present captain's main: $(cat "$home/state/.supervision-host.log")"
  assert_re '	handled	turn=[^	]*	posture=attended	' "$home/state/.supervision-host.log" "a quiet record must leave the host's turn attended"
  assert_no_re '^POSTURE: AWAY' "$home/engine-call.1" "a turn beside a quiet record must carry no away tail"
  assert_re 'MAIN DIALOG MIRROR' "$home/engine-call.1" "a turn beside a quiet record must carry the captain's dialog"
  assert_grep 'MAIN processes it from its next drain' "$home/engine-report.log" "a captain report beside a quiet record must say main processes it"
  assert_re '^supervision-host: branch-outcome: .*\(store rows 1\); run bin/fm-wake-drain.sh' "$home/host.out" \
    "the exit must name the captain outcome's store row for the present captain"
  drained=$(FM_HOME="$home" "$FAKE_CLAUDE" -c '"$0" 2>&1' "$ROOT/bin/fm-wake-drain.sh")
  assert_contains "$drained" "BRANCH OUTCOMES (captain outcomes the supervision session recorded for you" "main's drain must present the captain outcome beside a quiet record"
  assert_contains "$drained" " ago] demo: stub escalated: " "the section must carry the outcome"
  [ -f "$home/state/.afk-contract" ] || fail "the host must leave quiet mode's record in place"

  home=$(make_home quiet-main-only quiet)
  start_host "$home"
  wait_until 150 watcher_live "$home" || fail "quiet main-only: the host never started a watcher cycle"
  append_status "$home" 'which export format?' needs-decision
  wait_until_deadline 60 host_exited "$home" || fail "quiet main-only: the decision close did not reach main: $(cat "$home/state/.supervision-host.log")"
  assert_re '^signal: .*demo.status' "$home/host.out" "the decision close must reach main as the arm printed it"
  [ "$(engine_calls "$home")" -eq 0 ] || fail "quiet main-only: the engine took a decision close from a present captain"
  assert_re '	pass-through	attended	main-only	signal:' "$home/state/.supervision-host.log" "the ledger must record the attended main-only pass-through"
  pass "host: a quiet record without its daemon is a present captain, so outcomes and decisions reach main"
}

test_attended_main_only_close_passes_straight_to_main() {
  local home
  home=$(make_home attended-main-only attended)
  start_host "$home"
  wait_until 150 watcher_live "$home" || fail "main-only: the host never started a watcher cycle"
  append_status "$home" 'which export format?' needs-decision
  wait_until_deadline 60 host_exited "$home" || fail "main-only: the decision close did not reach main: $(cat "$home/state/.supervision-host.log")"
  expect_code 0 "$(cat "$home/host.rc")" "a main-only close must exit 0"
  assert_re '^signal: .*demo.status' "$home/host.out" "the close must carry the watcher's reason line"
  assert_no_re '^supervision-host' "$home/host.out" "a main-only close must reach main exactly as the arm printed it"
  [ "$(engine_calls "$home")" -eq 0 ] || fail "main-only: the engine ran for a decision close"
  assert_grep 'demo.status' "$home/state/.wake-queue" "the decision wake must stay queued for main"
  assert_re '	pass-through	attended	main-only	signal:' "$home/state/.supervision-host.log" "the ledger must record why the close went to main"
  pass "host: an attended decision close stays main's exactly as the plain arm delivers it"
}


# The file is read at every wake (docs/configuration.md "Supervision host"), so
# an off written while the host is parked sends the next attended close to main
# exactly as the arm printed it, with the ledger naming the opt-out.

test_off_written_while_parked_passes_the_next_attended_close_to_main() {
  local home
  home=$(make_home attended-off-while-parked attended)
  start_host "$home"
  wait_until 150 watcher_live "$home" || fail "off while parked: the host never started a watcher cycle"
  : > "$home/config/supervision-host-off"
  append_status "$home" 'step one'
  wait_until_deadline 60 host_exited "$home" || fail "off while parked: the close did not reach main: $(cat "$home/state/.supervision-host.log")"
  expect_code 0 "$(cat "$home/host.rc")" "a close on a home that opted out must exit 0"
  assert_re '^signal: .*demo.status' "$home/host.out" "the close must carry the watcher's reason line"
  assert_no_re '^supervision-host' "$home/host.out" "the close must reach main exactly as the arm printed it"
  [ "$(engine_calls "$home")" -eq 0 ] || fail "off while parked: the engine ran after the home opted out"
  assert_re '	pass-through	attended	the home does not run the supervision host	signal:' "$home/state/.supervision-host.log" \
    "the ledger must name the opt-out as why the close went to main"
  stop_home_processes "$home"
  pass "host: an off written while the host is parked sends the next attended close to main, naming the opt-out"
}


# The live failure this guards: a main-only pass-through used to exit without
# a watcher, so nothing restarted short-lived listeners until the session
# armed again. The close still reaches main unchanged, and the successor
# cycle stays up for the session's next arm to attach to.

test_main_only_pass_through_leaves_the_successor_watcher_running() {
  local home pid
  home=$(make_home main-only-successor attended)
  start_host "$home"
  wait_until 150 watcher_live "$home" || fail "successor: the host never started a watcher cycle"
  append_status "$home" 'which export format?' needs-decision
  wait_until_deadline 60 host_exited "$home" || fail "successor: the decision close did not reach main: $(cat "$home/state/.supervision-host.log")"
  expect_code 0 "$(cat "$home/host.rc")" "a main-only close must exit 0"
  assert_re '^signal: .*demo.status' "$home/host.out" "the close must carry the watcher's reason line"
  assert_no_re '^supervision-host' "$home/host.out" "a main-only close must reach main exactly as the arm printed it"
  [ "$(engine_calls "$home")" -eq 0 ] || fail "successor: the engine ran for a decision close"
  watcher_live "$home" || fail "successor: the pass-through left no live watcher: $(cat "$home/state/.supervision-host.log")"
  [ "$(marker_kind "$home")" = downtime ] \
    || fail "successor: the pass-through claimed the close was being handled, so main's re-arm owner would not deliver it: $(cat "$home/state/.watcher-down")"
  pid=$(cat "$home/state/.watch.lock/pid")
  sleep 2
  kill -0 "$pid" 2>/dev/null || fail "successor: the watcher exited after the pass-through (pid $pid)"
  [ "$(cat "$home/state/.watch.lock/pid" 2>/dev/null)" = "$pid" ] || fail "successor: the watcher lock moved after the pass-through"
  pass "host: a main-only pass-through leaves the successor watcher running and the close undelivered for main"
}


# The session-lock holder's process identity cannot be read (its proc entry
# is truncated), so no main-session key exists: the close reaches main exactly
# as the arm printed it, before any mirror feed or engine turn.

test_attended_close_with_unidentified_main_session_passes_to_main() {
  local home
  home=$(make_home attended-unidentified attended)
  FM_HOME="$home" FM_CREW_STATE_BIN="$home/fakebin/fm-crew-state.sh" PATH="$home/fakebin:$PATH" \
    "$FAKE_CLAUDE" -c '
      printf "%s\n" "$$" > "$FM_HOME/state/.lock"
      printf "%s\n" "$$" >> "$FM_HOME/claude-pids"
      mkdir -p "$FM_HOME/proc/$$"
      printf "%s (claude) S\n" "$$" > "$FM_HOME/proc/$$/stat"
      printf "claude\0" > "$FM_HOME/proc/$$/cmdline"
      export FM_PROC_ROOT_OVERRIDE="$FM_HOME/proc"
      "$0" park > "$FM_HOME/host.out" 2>&1
      printf "%s\n" "$?" > "$FM_HOME/host.rc"
    ' "$HOST" 2>> "$home/claude.err" &
  wait_until 150 watcher_live "$home" || fail "unidentified: the host never started a watcher cycle: $(cat "$home/host.out")"
  append_status "$home" 'step one'
  wait_until_deadline 60 host_exited "$home" || fail "unidentified: the close did not reach main: $(cat "$home/state/.supervision-host.log")"
  expect_code 0 "$(cat "$home/host.rc")" "a close for an unidentified main session must exit 0"
  assert_re '^signal: .*demo.status' "$home/host.out" "the close must carry the watcher's reason line"
  assert_no_re '^supervision-host' "$home/host.out" "the close must reach main exactly as the arm printed it"
  [ "$(engine_calls "$home")" -eq 0 ] || fail "unidentified: the engine ran without a main-session key"
  assert_grep 'demo.status' "$home/state/.wake-queue" "the wake must stay queued for main"
  assert_re '	pass-through	attended	the main session could not be identified	signal:' "$home/state/.supervision-host.log" \
    "the ledger must record why the close went to main"
  pass "host: an attended close whose main session cannot be identified reaches main and runs no engine turn"
}


# The captain returns after the loop accepted a decision close away but before
# its turn starts: the turn meets the attended rule, so the close still reaches
# main exactly as the arm printed it instead of being scoped to nothing.

test_close_accepted_away_that_turns_attended_passes_to_main() {
  local home real_mktemp
  home=$(make_home away-then-attended away)
  printf '{"hook_event_name":"UserPromptSubmit","prompt_id":"p0","prompt":"watch the fleet for me"}' > "$home/mirror-seed.0"
  real_mktemp=$(command -v mktemp)
  # Starting the successor arm is the first step after the loop's away check;
  # once the decision line is queued, the captain returns there.
  cat > "$home/fakebin/mktemp" <<SH
#!/usr/bin/env bash
case "\$*" in
  *.supervision-host-arm.*)
    ! grep -q 'which export format?' "\$FM_HOME/state/demo.status" 2>/dev/null \
      || "\$FM_REPO/bin/fm-afk-contract.sh" archive >> "\$FM_HOME/engine-return.log" 2>&1 ;;
esac
exec "$real_mktemp" "\$@"
SH
  chmod +x "$home/fakebin/mktemp"
  start_host "$home"
  wait_until 150 watcher_live "$home" || fail "away-then-attended: the host never started a watcher cycle"
  append_status "$home" 'which export format?' needs-decision
  wait_until_deadline 60 host_exited "$home" || fail "away-then-attended: the decision close did not reach main: $(cat "$home/state/.supervision-host.log")"
  assert_absent "$home/state/.afk-contract" "fixture: the captain did not return before the turn"
  expect_code 0 "$(cat "$home/host.rc")" "the close must exit 0"
  assert_re '^signal: .*demo.status' "$home/host.out" "the close must carry the watcher's reason line"
  assert_no_re '^supervision-host' "$home/host.out" "the close must reach main exactly as the arm printed it"
  [ "$(engine_calls "$home")" -eq 0 ] || fail "away-then-attended: the engine ran for a decision close"
  assert_grep 'demo.status' "$home/state/.wake-queue" "the decision wake must stay queued for main"
  assert_re '	pass-through	attended	main-only	signal:' "$home/state/.supervision-host.log" "the ledger must record why the close went to main"
  assert_no_re '	no-op	' "$home/state/.supervision-host.log" "the close must not be treated as handled"
  watcher_live "$home" || fail "the pass-through left no successor watcher"
  pass "host: a decision close accepted away whose turn starts attended still reaches main unchanged"
}

test_attended_close_that_turns_main_only_before_its_turn_passes_to_main() {
  local home
  home=$(make_home attended-turns-main-only attended)
  turn_main_only_at_second_offer "$home" snapshot
  start_host "$home"
  wait_until 150 watcher_live "$home" || fail "turns-main-only: the host never started a watcher cycle"
  append_status "$home" 'step one'
  wait_until_deadline 60 host_exited "$home" || fail "turns-main-only: the close did not reach main: $(cat "$home/state/.supervision-host.log")"
  assert_grep 'which export format?' "$home/state/demo.status" "fixture: the decision was not recorded before the turn"
  expect_code 0 "$(cat "$home/host.rc")" "the close must exit 0"
  assert_re '^signal: .*demo.status' "$home/host.out" "the close must carry the watcher's reason line"
  assert_no_re '^supervision-host' "$home/host.out" "the close must reach main exactly as the arm printed it"
  [ "$(engine_calls "$home")" -eq 0 ] || fail "turns-main-only: the engine ran on a stale offer"
  assert_grep 'demo.status' "$home/state/.wake-queue" "the wake must stay queued for main"
  assert_grep 'which export format?' "$home/pi-offer-state/demo.status" "fixture: the Pi snapshot must contain the new decision"
  assert_no_re 'needs-decision:' "$home/pi-offer-state/.wake-queue" "fixture: the Pi snapshot must contain only the accepted wake"
  local pi_offer
  pi_offer=$(node --input-type=module -e '
    const dispatch = await import(process.argv[1]);
    console.log(dispatch.branchOfferForWake(process.argv[2], process.argv[3], false).eligible);
  ' "$ROOT/.pi/extensions/lib/fm-branch-dispatch.ts" "$home/pi-offer-state" "signal: $home/state/demo.status")
  [ "$pi_offer" = true ] || fail "the host-only transition veto changed Pi's existing offer rule"
  assert_re '	pass-through	attended	main-only	signal:' "$home/state/.supervision-host.log" "the ledger must record why the close went to main"
  watcher_live "$home" || fail "the pass-through left no successor watcher"
  pass "host: an attended close whose task turns main-only before its turn still reaches main unchanged"
}


# Grok and OpenCode have no mirror writer, because they cannot record a
# session's first captain prompt, and neither Codex nor omp has a proven one,
# so none of them has a verified dialog mirror: every attended close reaches
# main as without the host, while the away posture, which needs no mirror,
# still runs on the engine.

test_primary_without_a_verified_mirror_runs_away_only() {
  local home harness
  for harness in grok opencode omp codex; do
    home=$(make_home "attended-$harness" attended claude)
    FM_SUPERVISION_HOST_PRIMARY=$harness start_host "$home"
    wait_until 150 watcher_live "$home" || fail "$harness: the host never started a watcher cycle"
    append_status "$home" 'fixture finished' 'done'
    wait_until_deadline 60 host_exited "$home" || fail "$harness: the host did not hand the attended close to main"
    assert_re '^signal: .*demo.status' "$home/host.out" "the close must carry the watcher's reason line"
    assert_no_re '^supervision-host' "$home/host.out" "the close must reach main exactly as the arm printed it"
    [ "$(engine_calls "$home")" -eq 0 ] || fail "$harness: the engine ran an attended wake without a verified dialog mirror"
    assert_re "	pass-through	attended	no verified dialog mirror for $harness	" "$home/state/.supervision-host.log" \
      "the ledger must record that no verified mirror kept the close on main"
  done
  home=$(make_home away-grok away claude)
  FM_SUPERVISION_HOST_PRIMARY=grok start_host "$home"
  wait_until 150 watcher_live "$home" || fail "away grok: the host never started a watcher cycle"
  append_status "$home" 'step one'
  wait_until 250 handled_at_least "$home" 1 \
    || fail "away grok: the wake was not handled on the engine: $(cat "$home/host.out"; cat "$home/state/.supervision-host.log")"
  assert_re '^primary=grok$' "$home/engine-call.1" "the away engine must carry the grok primary pin"
  assert_re '^POSTURE: AWAY\.' "$home/engine-call.1" "the away wake must carry the away tail"
  [ ! -s "$home/host.rc" ] || fail "a handled away wake on grok reached main: $(cat "$home/host.out")"
  kill -TERM "$(awk -F '\t' '$1 == "host" { print $2 }' "$home/state/.supervision-host")"
  wait_until_deadline 60 host_exited "$home" || fail "away grok: the host did not stop on TERM"
  pass "host: a primary with no verified dialog mirror keeps every attended close on main, and its away posture still runs"
}

test_attended_wake_carries_the_dialog_mirror() {
  local home first second
  home=$(make_home attended-mirror attended)
  printf '{"hook_event_name":"UserPromptSubmit","prompt_id":"p1","prompt":"keep the export worker on low effort"}' > "$home/mirror-seed.1"
  printf '{"hook_event_name":"Stop","prompt_id":"p1","last_assistant_message":"Understood, low effort it is."}' > "$home/mirror-seed.2"
  printf '{"hook_event_name":"UserPromptSubmit","prompt_id":"p2","prompt":"\342\201\243FIRSTMATE_OP: v1 watcher: signal: demo.status"}' > "$home/mirror-seed.3"
  start_host "$home"
  wait_until 150 watcher_live "$home" || fail "mirror: the host never started a watcher cycle"
  append_status "$home" 'step one'
  wait_until 250 handled_at_least "$home" 1 || fail "mirror: the wake was not handled: $(cat "$home/state/.supervision-host.log")"
  first="$home/engine-call.1"
  assert_re '^arg=MAIN DIALOG MIRROR \(read-only context' "$first" "the wake must open with the dialog mirror"
  assert_re '^\[captain\] keep the export worker on low effort$' "$first" "the mirror must carry the captain's words"
  assert_re '^\[main\] Understood, low effort it is\.$' "$first" "the mirror must carry main's reply"
  assert_no_re 'FIRSTMATE_OP' "$first" "operational input must never be mirrored as dialog"
  append_status "$home" 'step two'
  wait_until 250 handled_at_least "$home" 2 || fail "mirror: the second wake was not handled"
  second="$home/engine-call.2"
  assert_re '^arg=--resume$' "$second" "fixture: the second turn did not resume the conversation"
  assert_no_re 'MAIN DIALOG MIRROR' "$second" "a resumed conversation must not be fed dialog it already has"
  pass "host: each wake carries the captain's dialog since the last wake, without operational input"
}


# Every file carrying the captain's dialog is owner-only, even under an open
# umask and when a readable copy was already there. The feed is removed before
# the engine starts, so a node wrapper records its mode as the wake renders.

test_dialog_bearing_files_are_owner_only() {
  local home old
  home=$(make_home attended-private attended)
  {
    printf '#!/usr/bin/env bash\nREAL_NODE=%q\n' "$(command -v node)"
    cat <<'SH'
prev=
for a in "$@"; do
  [ "$prev" != --mirror-file ] || { stat -c %a "$a" 2>/dev/null || stat -f %Lp "$a"; } >> "$FM_HOME/feed-modes"
  prev=$a
done
exec "$REAL_NODE" "$@"
SH
  } > "$home/fakebin/node"
  chmod +x "$home/fakebin/node"
  old=$(umask)
  umask 022
  for f in .host-mirror.jsonl .supervision-host-mirror .supervision-host-wake; do
    : > "$home/state/$f"
    chmod 644 "$home/state/$f"
  done
  start_host "$home"
  umask "$old"
  wait_until 150 watcher_live "$home" || fail "private: the host never started a watcher cycle"
  append_status "$home" 'step one'
  wait_until 250 handled_at_least "$home" 1 || fail "private: the wake was not handled: $(cat "$home/state/.supervision-host.log")"
  assert_re '^\[captain\] watch the fleet for me$' "$home/engine-call.1" "fixture: the wake must carry the captain's words"
  [ "$(mode_of "$home/state/.host-mirror.jsonl")" = 600 ] || fail "the dialog mirror must be owner-only, got $(mode_of "$home/state/.host-mirror.jsonl")"
  [ "$(mode_of "$home/state/.supervision-host-wake")" = 600 ] || fail "the wake file must be owner-only, got $(mode_of "$home/state/.supervision-host-wake")"
  [ "$(cat "$home/feed-modes" 2>/dev/null)" = 600 ] || fail "the mirror feed must be owner-only, got $(cat "$home/feed-modes" 2>/dev/null)"
  pass "host: the dialog mirror, its feed, and the wake file are owner-only"
}

fm_test_run \
  test_park_exit_probe_uses_half_second_child_sleeps \
  test_attended_routine_wake_is_handled_on_the_engine_and_stays_off_main \
  test_host_stopped_right_after_a_handled_wake_exits_and_frees_the_queue \
  test_engine_in_another_time_zone_handles_its_granted_rows \
  test_attended_captain_outcome_reaches_main_through_branch_outcomes \
  test_captain_leaving_mid_turn_keeps_its_captain_outcome_for_the_return \
  test_quiet_record_without_its_daemon_is_a_present_captain \
  test_attended_main_only_close_passes_straight_to_main \
  test_off_written_while_parked_passes_the_next_attended_close_to_main \
  test_main_only_pass_through_leaves_the_successor_watcher_running \
  test_attended_close_with_unidentified_main_session_passes_to_main \
  test_close_accepted_away_that_turns_attended_passes_to_main \
  test_attended_close_that_turns_main_only_before_its_turn_passes_to_main \
  test_primary_without_a_verified_mirror_runs_away_only \
  test_attended_wake_carries_the_dialog_mirror \
  test_dialog_bearing_files_are_owner_only
