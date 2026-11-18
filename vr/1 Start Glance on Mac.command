#!/bin/zsh
# Double-click: starts Glance on this Mac for the headset (USB cable only). Keep this window open.
cd "$(dirname "$0")/.."; [[ -f Package.swift ]] || cd Glance
GLANCE_QUEST_LAN=0 swift run -c release Glance
