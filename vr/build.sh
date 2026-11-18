#!/bin/zsh
# Builds Glance VR for Meta Quest, release-signed: builds/GlanceVR.apk
#   zsh build.sh          (or: zsh build.sh 2   to set the version code; every Dashboard upload needs a higher one)
#   zsh cable.sh install  (installs it on a plugged-in headset)
# The app contains no addresses or secrets: at runtime it finds the Glance app on your Mac by itself.
source "${0:A:h}/build-common.sh"
build_apk headset builds/GlanceVR.apk "$1"
echo "Done. Install it with: zsh cable.sh install   — then just open Glance on the Mac and Glance VR in the headset."
