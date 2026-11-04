# Plays a driver scene without recording (setup steps):  drive.sh <scene.json>
cd "${0:A:h}/../.."
GLANCE_DEMO_VOICE=$PWD/demo/.voice demo/.bin/driver "$1" demo/logs/drive.events.json
