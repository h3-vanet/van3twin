#!/usr/bin/env bash

set -e

ROOT_DIR="${1:-src}"

echo "[+] Searching Sionna-related usages in: $ROOT_DIR"
echo

patterns=(
    "SionnaHelper"
    "getLOSStatusFromSionna"
    "SetSionna"
    "SetSionnaUp"
    "sionna-helper.h"
)

for pattern in "${patterns[@]}"; do
    echo "=================================================="
    echo "[+] Pattern: $pattern"
    echo "=================================================="

    matches=$(grep -RIn --exclude-dir=.git "$pattern" "$ROOT_DIR" || true)

    if [ -z "$matches" ]; then
        echo "No matches found."
    else
        echo "$matches"
    fi

    echo
done

echo "=================================================="
echo "[+] Checking for NON-WRAPPED sionna-helper includes"
echo "=================================================="

grep -RIl --exclude-dir=.git 'sionna-helper.h' "$ROOT_DIR" | while read -r file; do

    if ! grep -q '#ifdef NS3_SIONNA' "$file"; then
        echo "[WARNING] Possible unwrapped include in:"
        echo "  $file"
        echo
    fi
done

echo
echo "[+] Done."