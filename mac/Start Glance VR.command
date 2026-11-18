#!/bin/zsh
# Double-click to start Glance VR on this Mac. Keep this window open while you use the headset.
cd "$(dirname "$0")"
swift run -c release GlanceVR
