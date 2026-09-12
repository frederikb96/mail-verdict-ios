#!/usr/bin/env bash
# Assert ContractRegistry.all lists every ContractModel conformance in the package — a hand-
# written "covers every X" list drifts the moment someone adds a model and forgets to register it,
# so this derives the expected list from the source itself rather than trusting the registry to be
# honest about its own completeness.

set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
sources="$root/MailVerdictKit/Sources/MailVerdictKit/Models"
registry="$sources/ContractRegistry.swift"

# A conformance looks like `struct Foo: ContractModel, ...` or `, ContractModel,` / `, ContractModel {`
# — never `protocol ContractModel` or `ContractModel.Type` itself.
#
# 🚨 Membership below is checked with an associative array, never `printf '%s\n' "${arr[@]}" |
# grep -qx "$name"` — `grep -q` exits the instant it finds a match, and under `pipefail` the
# `printf` side then dies of SIGPIPE with a non-zero status that becomes the *pipeline's* status
# (pipefail reports the last non-zero exit, not the rightmost command's own), intermittently
# flipping a present name to "missing" depending on exactly when the SIGPIPE lands. Cost two hours
# of "is this real" on a result that was right 4 times out of 5 before this was understood.
mapfile -t conforming < <(
    command grep -rhoE '(struct|class|enum) [A-Za-z0-9_]+: [A-Za-z0-9_, ]*\bContractModel\b' "$sources" \
        | sed -E 's/^(struct|class|enum) ([A-Za-z0-9_]+):.*/\2/' \
        | sort -u
)

mapfile -t registered < <(
    command grep -oE '^\s*[A-Za-z0-9_]+\.self,' "$registry" \
        | sed -E 's/^\s*([A-Za-z0-9_]+)\.self,/\1/' \
        | sort -u
)

declare -A registered_set=()
for name in "${registered[@]}"; do registered_set["$name"]=1; done

declare -A conforming_set=()
for name in "${conforming[@]}"; do conforming_set["$name"]=1; done

missing=()
for name in "${conforming[@]}"; do
    [ -n "${registered_set[$name]+x}" ] || missing+=("$name")
done

extra=()
for name in "${registered[@]}"; do
    [ -n "${conforming_set[$name]+x}" ] || extra+=("$name")
done

status=0
if [ ${#missing[@]} -gt 0 ]; then
    echo "ContractRegistry.all is missing: ${missing[*]}"
    status=1
fi
if [ ${#extra[@]} -gt 0 ]; then
    echo "ContractRegistry.all lists a type that no longer conforms to ContractModel: ${extra[*]}"
    status=1
fi

if [ "$status" -eq 0 ]; then
    echo "ContractRegistry.all matches every ContractModel conformance (${#conforming[@]} types)"
fi
exit "$status"
