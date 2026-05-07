#!/usr/bin/env bash

set -e

ROOT_DIR="${1:-src}"

echo "[+] Auto-wrapping sionna-helper includes in: $ROOT_DIR"
echo

FILES=$(grep -RIl --exclude-dir=.git 'sionna-helper.h' "$ROOT_DIR" || true)

if [ -z "$FILES" ]; then
    echo "[+] No files found."
    exit 0
fi

for file in $FILES; do

    echo "[+] Processing: $file"

    # Skip if already wrapped
    if grep -A1 '#ifdef NS3_SIONNA' "$file" | grep -q 'sionna-helper.h'; then
        echo "    Already wrapped. Skipping."
        continue
    fi

    # Replace include with wrapped version
    sed -i \
        '/#include "ns3\/sionna-helper.h"/c\
#ifdef NS3_SIONNA\
#include "ns3/sionna-helper.h"\
#endif' \
        "$file"

    echo "    Wrapped successfully."

done

echo
echo "[+] Done."