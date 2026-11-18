#!/bin/zsh
# Regression check for the Quest project: a headless Godot import must report no script errors.
#   zsh quest/check-project.sh        (GODOT=<path to Godot binary> if not the default below)
set -e
cd "${0:A:h}"
GODOT="${GODOT:-/Applications/Godot.app/Contents/MacOS/Godot}"
[[ -x "$GODOT" ]] || GODOT="$(command -v godot || true)"
[[ -n "$GODOT" && -x "$GODOT" ]] || { echo "No Godot binary found. Set GODOT=<path>."; exit 1; }
out="$("$GODOT" --headless --import --path glance-gaze 2>&1)" || { echo "$out" | tail -20; exit 1; }
if echo "$out" | grep -qE "SCRIPT ERROR|Parse Error|Failed to load script"; then
	echo "$out" | grep -E "SCRIPT ERROR|Parse Error|Failed to load script"
	exit 1
fi
echo "Quest project imports with no script errors."
