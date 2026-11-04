# Records the screen (and the camera with --camera) while a driver scene plays, or for a fixed time.
#   record.sh <take-name> <scene.json | seconds> [--camera]
# Writes demo/takes/<take>.screen.mov, <take>.camera.mov and <take>.events.json (wall-clock times of every step,
# plus "recordStart" so the editor can line things up).
cd "${0:A:h}/../.."
take=$1; what=$2; camera=$3
out=demo/takes/$take
python3 -c "import json,time; json.dump({'recordStart': time.time()}, open('$out.start.json','w'))"
ffmpeg -y -loglevel error -f avfoundation -capture_cursor 1 -framerate 30 -pixel_format nv12 -i "Capture screen 0:none" \
  -c:v h264_videotoolbox -b:v 24M -pix_fmt yuv420p "$out.screen.mov" < /dev/null &
screen=$!
if [[ $camera == --camera ]]; then
  ffmpeg -y -loglevel error -f avfoundation -framerate 30 -video_size 1280x720 -i "MacBook Air Camera:none" \
    -c:v h264_videotoolbox -b:v 8M "$out.camera.mov" < /dev/null &
  cam=$!
fi
sleep 1.5
if [[ $what == *.json ]]; then
  GLANCE_DEMO_VOICE=$PWD/demo/.voice demo/.bin/driver "$what" "$out.events.json"
else
  sleep "$what"
fi
sleep 1
kill -INT $screen ${cam:-} 2>/dev/null
wait
ls -la "$out".*
