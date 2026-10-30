#!/usr/bin/env bash
# The plain launch, then every registered screen by name in fixture mode. Every screen is attempted
# even after one fails, and the script fails once at the end.
#
# The debug bridge and fixture mode are `#if DEBUG`, so a Release build has none of this.
#
# Environment:
#   SIM_UDID      the booted simulator
#   ONLY          comma-separated screen ids; empty runs all, `none` only the plain launch. A name
#                 matching nothing fails.
#   PROBE         a script sourced at the end; $udid, $bundle and `terminate_and_wait` are in scope
#   CONTENT_SIZE  `accessibility-large` for the large Dynamic Type sweep
set -o pipefail
# shellcheck source=lib.sh
. "$(dirname -- "${BASH_SOURCE[0]}")/lib.sh"

mkdir -p artifacts artifacts/logs
udid="${SIM_UDID:?SIM_UDID is required}"
bundle=$BUNDLE
ONLY=${ONLY:-}
fail=0

# True when nothing was selected, or the name was.
want() {
  [ -z "$ONLY" ] && return 0
  case ",$ONLY," in *",$1,"*) return 0 ;; esac
  return 1
}

# A plain, non-fixture launch: the sign-in screen by design, since no Keychain credential exists on
# a fresh simulator. Proof the real launch path still reaches it.
xcrun simctl launch "$udid" "$bundle" > /dev/null
ok=0
for attempt in $(seq 1 10); do
  if curl -sS --max-time 3 "http://127.0.0.1:8765/health" -o artifacts/health.json; then
    ok=1
    break
  fi
  sleep 2
done
if [ "$ok" -ne 1 ]; then
  echo "::warning::debug bridge never answered"
  fail=1
fi
curl -sS --max-time 3 "http://127.0.0.1:8765/routes" -o artifacts/routes.json || true

# The bridge starts listening before the first frame is drawn, so "/health answered"
# proves the process is alive and proves nothing about the screen. Settle before the
# screenshot, same reasoning as every other screenshot workflow in this family.
sleep 6
xcrun simctl io "$udid" screenshot artifacts/screen-root.png
bytes=$(stat -f %z artifacts/screen-root.png)
echo "root: ${bytes} bytes"
if [ "$bytes" -le 20000 ]; then
  echo "::warning::screenshot suspiciously small — the screen may be blank"
  fail=1
fi
curl -sS --max-time 3 "http://127.0.0.1:8765/logs?level=info&limit=200" \
  -o artifacts/logs.json || true
xcrun simctl terminate "$udid" "$bundle" || true

# `simctl terminate` returns once the request is issued, not once the process and its
# debug-bridge listener are actually gone — relaunching before that finishes risks the
# new launch racing the old process, which is what let one screen's `/fixtures/misses`
# carry the previous screen's own still-in-flight requests. Both signals have to clear:
# the process itself (`launchctl list`) and the port it was listening on (refused, not
# merely timed out, is what "nothing is there" looks like).
terminate_and_wait() {
  xcrun simctl terminate "$udid" "$bundle" || true
  for attempt in $(seq 1 10); do
    if ! xcrun simctl spawn "$udid" launchctl list 2>/dev/null | grep -q "$bundle" \
      && ! curl -sS --max-time 1 "http://127.0.0.1:8765/health" >/dev/null 2>&1; then
      return 0
    fi
    sleep 1
  done
  echo "::warning::old process or its debug bridge had not gone away after 10s"
}

terminate_and_wait
xcrun simctl launch "$udid" "$bundle" -MVFixtureMode YES > /dev/null

ok=0
for attempt in $(seq 1 10); do
  if curl -sS --max-time 3 "http://127.0.0.1:8765/screens" -o artifacts/screens.json; then
    ok=1
    break
  fi
  sleep 2
done
if [ "$ok" -ne 1 ]; then
  echo "::error::debug bridge never answered /screens in fixture mode"
  terminate_and_wait
  exit 1
fi

# A plain `while read` rather than `mapfile` — the macOS runner's default `/bin/bash`
# is the ancient Apple-shipped 3.2, which does not have `mapfile` (bash 4+ only).
ids_list=$(python3 -c "import json; print('\n'.join(json.load(open('artifacts/screens.json'))['screens']))")
terminate_and_wait

if [ -z "$ids_list" ]; then
  echo "no registered screenshot ids yet — nothing to sweep"
fi

# A selection that matches nothing would pass by doing nothing.
for item in $(echo "$ONLY" | tr ',' ' '); do
  [ "$item" = none ] && continue
  case " $(echo "$ids_list" | tr '\n' ' ') " in
    *" $item "*) ;;
    *) echo "::error::only: '$item' is not a registered screen"; exit 1 ;;
  esac
done

# Dynamic Type is a per-process launch argument, not a simulator-wide setting like
# appearance above — every relaunch in the sweep below needs it repeated.
content_size_args=()
if [ "${CONTENT_SIZE:-default}" = "accessibility-large" ]; then
  content_size_args=(-UIPreferredContentSizeCategoryName UICTContentSizeCategoryAccessibilityL)
fi

while IFS= read -r id; do
  [ -n "$id" ] && want "$id" || continue
  # A fresh process starts this ring empty anyway, but `since` is what keeps this
  # screen's own dump from also carrying the previous screen's entries if its process
  # (and bridge) were not entirely gone by the time this one launched.
  since=$(date -u +%s)
  xcrun simctl launch "$udid" "$bundle" -MVFixtureMode YES -MVFixtureScreen "$id" \
    "${content_size_args[@]}" > /dev/null

  reached=0
  for attempt in $(seq 1 15); do
    current=$(curl -sS --max-time 3 "http://127.0.0.1:8765/screen/current" 2>/dev/null \
      | python3 -c "import json,sys; print(json.load(sys.stdin).get('id') or '')" 2>/dev/null || echo "")
    if [ "$current" = "$id" ]; then
      reached=1
      break
    fi
    sleep 2
  done

  if [ "$reached" -ne 1 ]; then
    echo "::error::screen '$id' never reported ready on /screen/current"
    # The debug bridge never answering again is exactly what a dead process looks
    # like too — `launchctl list` is what actually distinguishes "still starting up
    # slowly" from "crashed and gone", rather than leaving that to be guessed from the
    # device log, which carries nothing about a crash at all.
    if ! xcrun simctl spawn "$udid" launchctl list 2>/dev/null | grep -q "$bundle"; then
      echo "screen $id: app crashed"
    fi
    # Whatever is actually on screen when a screen fails to settle, captured anyway —
    # and whether the main actor itself ever answers tells "pushed but its view never
    # appeared" apart from "nothing will ever appear, the main actor is stuck", which a
    # bridge route answering from its own queue (every other one here) cannot.
    xcrun simctl io "$udid" screenshot "artifacts/screen-$id-notready.png" || true
    probe=$(curl -sS --max-time 3 "http://127.0.0.1:8765/main-actor-probe" 2>/dev/null || echo "")
    if [ -n "$probe" ]; then
      echo "screen $id: main-actor-probe answered: $probe"
    else
      echo "screen $id: main-actor-probe did not answer within 3s — main actor may be stuck"
    fi
    fail=1
  else
    xcrun simctl io "$udid" screenshot "artifacts/screen-$id.png"
    bytes=$(stat -f %z "artifacts/screen-$id.png")
    echo "$id: ${bytes} bytes"
    if [ "$bytes" -le 20000 ]; then
      echo "::warning::screenshot for '$id' suspiciously small — the screen may be blank"
      fail=1
    fi

    # A screen that silently fell back to an error state instead of its fixture still
    # "succeeds" the two checks above — this is what actually proves every request it
    # made was answered by the table rather than reaching the real network.
    misses=$(curl -sS --max-time 3 "http://127.0.0.1:8765/fixtures/misses" 2>/dev/null \
      | python3 -c "import json,sys; print(','.join(json.load(sys.stdin).get('misses') or []))" 2>/dev/null || echo "")
    if [ -n "$misses" ]; then
      echo "::error::screen '$id' hit request(s) no fixture route answered: $misses"
      fail=1
    fi

    # Each AppEnvironment owns a live stream and an intent ledger, and a second one is
    # invisible on screen — it shows up as the server being hammered and the app's own
    # requests timing out behind the extra streams. Two are legitimate: the shell's, and
    # the short-lived stand-in push registration builds when no shell has attached yet.
    # An unanswered route must read as a failure, not as a zero: a check that cannot
    # reach its measurement proves nothing and looks exactly like a pass.
    envs=$(curl -sS --max-time 3 "http://127.0.0.1:8765/shell/state" 2>/dev/null \
      | python3 -c "import json,sys; print(json.load(sys.stdin)['environmentsCreated'])" 2>/dev/null || echo "")
    echo "$id: $envs app environment(s)"
    if [ -z "$envs" ] || [ "$envs" -gt 2 ]; then
      echo "::error::screen '$id' reported '$envs' app environments — each one is another live stream and ledger"
      fail=1
    fi
  fi

  # Before terminate_and_wait, which is what makes this the last chance to ask this
  # screen's own process anything — /logs was otherwise only ever read once, before
  # this loop even starts, so no feature's own debug markers reached the artifacts for
  # any individual screen, success or failure alike.
  curl -sS --max-time 3 "http://127.0.0.1:8765/logs?since=$since&limit=500" \
    -o "artifacts/logs/$id.json" 2>/dev/null || true
  terminate_and_wait
done <<< "$ids_list"

# A probe is a branch-local script run with everything above in scope, so a question nobody has a
# screen for needs no change to the workflow.
if [ -n "${PROBE:-}" ]; then
  # shellcheck source=/dev/null
  . "$PROBE"
fi

[ "$fail" -eq 0 ] || { echo 'one or more checks failed — see the warnings above'; exit 1; }

