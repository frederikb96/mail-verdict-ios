# Probe: does the ticket timeline open with the Today marker near the middle of the viewport?
# Sourced at the end of Tooling/sim/sweep.sh (so $udid, $bundle and terminate_and_wait are in scope):
#   gh workflow run mac.yml -f script=Tooling/probes/orders-timeline.sh -f only=none
# Reads the debug bridge's /orders/state and fails when the marker is more than one row away from
# the viewport's middle, or is not on screen at all.
xcrun simctl launch "$udid" "$bundle" -MVFixtureMode YES -MVFixtureScreen orders-tickets > /dev/null

reached=0
for attempt in $(seq 1 15); do
  current=$(curl -sS --max-time 3 "http://127.0.0.1:8765/screen/current" 2>/dev/null \
    | python3 -c "import json,sys; print(json.load(sys.stdin).get('id') or '')" 2>/dev/null || echo "")
  [ "$current" = "orders-tickets" ] && { reached=1; break; }
  sleep 2
done
if [ "$reached" -ne 1 ]; then
  echo "::error::orders-tickets never reported ready"
  fail=1
else
  sleep 2
  curl -sS --max-time 3 "http://127.0.0.1:8765/orders/state" -o artifacts/orders-timeline-state.json
  cat artifacts/orders-timeline-state.json; echo
  python3 - <<'PY' || fail=1
import json
state = json.load(open("artifacts/orders-timeline-state.json"))
offset = state.get("markerOffsetFromCenter")
row = state.get("rowHeight") or 96
print(f"rows={state.get('rowCount')} todayIndex={state.get('todayIndex')} markerOffsetFromCenter={offset} rowHeight={row}")
if not state.get("markerVisible") or offset is None:
    raise SystemExit("::error::the Today marker is not on screen")
if abs(offset) > row:
    raise SystemExit(f"::error::the Today marker sits {offset}pt from the middle of the viewport (more than one row, {row}pt)")
PY
  xcrun simctl io "$udid" screenshot artifacts/screen-orders-timeline-probe.png
fi
terminate_and_wait
