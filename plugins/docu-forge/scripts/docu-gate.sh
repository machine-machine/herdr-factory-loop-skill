#!/usr/bin/env bash
# docu-gate.sh — thin shim; the gate itself is docu-gate.py (CSV quoting needs a real parser).
exec python3 "$(cd "$(dirname "$0")" && pwd)/docu-gate.py" "$@"
