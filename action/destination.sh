#!/bin/bash
# Step of the GitHub Action (action.yml): for an iOS / tvOS / watchOS / visionOS simulator, finds the device, boots
# it, waits until it has booted, and hands "id=<UDID>" on. The tool needs a booted simulator named by id: one that
# xcodebuild has to boot is shut down after every invocation. Other destinations are handed on as they are.
#
# With INPUT_SIMULATOR_PERMISSIONS it also grants permissions on the simulator ("<service> <bundle id>" per line, as
# for `xcrun simctl privacy <UDID> grant`): on a simulator that was just created, the system asks for a permission
# (camera, notifications, location, …) with a dialog over the app, the tests wait behind it whatever the mutant,
# and the tool gives the destination up after a few mutants.
#
# Environment: INPUT_DESTINATION, INPUT_SIMULATOR_PERMISSIONS. Output (to $GITHUB_OUTPUT): destination.
set -euo pipefail

DESTINATION="${INPUT_DESTINATION:-platform=macOS}"
field() { echo "$DESTINATION" | tr ',' '\n' | sed -n "s/^ *$1=//p" | head -1; }
UDID="$(field id)"
NAME="$(field name)"
PLATFORM="$(field platform)"
OS="$(field OS)"

if [[ -z "$UDID" && "$PLATFORM" == *Simulator* ]]; then
  if [[ -z "$NAME" ]]; then
    echo "::error::destination \"$DESTINATION\" names a simulator platform without name=<device name> or id=<UDID>."
    exit 64
  fi
  # The newest available runtime that has a device of that name (or the runtime of OS=<version>)
  UDID="$(xcrun simctl list devices available -j | /usr/bin/python3 -c '
import json, re, sys
name, wanted = sys.argv[1], sys.argv[2]
found = []
for runtime, devices in json.load(sys.stdin)["devices"].items():
    match = re.search(r"SimRuntime\.[A-Za-z]+-([0-9-]+)$", runtime)
    version = tuple(int(part) for part in match.group(1).split("-")) if match else ()
    if wanted and wanted != "latest" and ".".join(map(str, version)) != wanted and not ".".join(map(str, version)).startswith(wanted + "."):
        continue
    for device in devices:
        if device.get("name") == name and device.get("isAvailable", True):
            found.append((version, device["udid"]))
print(max(found)[1] if found else "")
' "$NAME" "$OS")"
  if [[ -z "$UDID" ]]; then
    echo "::error::no available simulator is named \"$NAME\"${OS:+ with OS $OS}. \"xcrun simctl list devices available\" shows what the runner has."
    xcrun simctl list devices available || true
    exit 64
  fi
  echo "simulator \"$NAME\": $UDID"
fi

if [[ -n "$UDID" ]] && xcrun simctl list devices | grep -q "$UDID"; then
  xcrun simctl boot "$UDID" 2>/dev/null || true      # already booted: fine
  xcrun simctl bootstatus "$UDID" -b
  DESTINATION="id=$UDID"
  granted=0
  while read -r service bundle rest; do
    [[ -z "${service:-}" ]] && continue
    if [[ -z "${bundle:-}" || -n "${rest:-}" ]]; then
      echo "::error::simulator-permissions: each line is \"<service> <bundle id>\" (got: $service ${bundle:-} ${rest:-})."
      exit 64
    fi
    xcrun simctl privacy "$UDID" grant "$service" "$bundle"
    echo "granted $service to $bundle on $UDID"
    granted=$((granted + 1))
  done <<<"${INPUT_SIMULATOR_PERMISSIONS:-}"
  if [[ "$granted" == 0 ]]; then
    echo "note: no permission was granted on the simulator (input simulator-permissions). If the app asks for one (camera, notifications, location, …), the system dialog stops the tests on a new simulator."
  fi
fi

echo "destination=$DESTINATION" >>"$GITHUB_OUTPUT"
echo "destination: $DESTINATION"
