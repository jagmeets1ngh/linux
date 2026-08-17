#!/usr/bin/env bash
# Install sriov-status into /usr/local/sbin
set -euo pipefail
PREFIX="${PREFIX:-/usr/local/sbin}"
SRC="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/sriov-status.sh"

[[ -r "$SRC" ]] || { echo "cannot find $SRC" >&2; exit 1; }
if [[ $EUID -ne 0 ]]; then
    echo "install.sh needs root (or set PREFIX to a writable directory)" >&2
    exit 1
fi
install -d -m 0755 "$PREFIX"
install -m 0755 "$SRC" "$PREFIX/sriov-status"
echo "installed: $PREFIX/sriov-status"
"$PREFIX/sriov-status" --version