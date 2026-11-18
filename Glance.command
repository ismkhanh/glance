#!/bin/zsh
# Reviewers: double-click this file, keep the window open, then open Glance Gaze on the Quest.
# The headset finds this Mac by itself on the same Wi-Fi; there is nothing else to set up.
cd "$(dirname "$0")"
swift run -c release Glance
