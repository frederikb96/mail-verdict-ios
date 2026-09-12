#!/usr/bin/env bash
# Vendor mail-verdict's published API contract snapshot at a given commit.
#
# The only writer of Tests/MailVerdictKitTests/Fixtures/api-contract/{openapi.json,sse-events.json,
# SYNCED_AT} — never hand-edit those files. `SYNCED_AT` records the sha so a later drift check, or
# a person reading the tree, knows exactly what this was last checked against.
#
# Usage: Tooling/sync-contract.sh <mail-verdict-sha>

set -euo pipefail

if [ $# -ne 1 ]; then
    echo "usage: $0 <mail-verdict-sha>" >&2
    exit 1
fi

sha="$1"
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
dest="$root/MailVerdictKit/Tests/MailVerdictKitTests/Fixtures/api-contract"
base_url="https://raw.githubusercontent.com/frederikb96/mail-verdict/$sha/docs/api-contract"

mkdir -p "$dest"

for name in openapi.json sse-events.json; do
    echo "fetching $name @ $sha"
    curl -fsSL "$base_url/$name" -o "$dest/$name"
done

echo "$sha" > "$dest/SYNCED_AT"

echo "vendored $dest against $sha"
