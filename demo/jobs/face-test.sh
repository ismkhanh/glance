# Face-region test: the Mac asks you to face each corner window (12 times, random order) while the camera
# records. Writes demo/facetest/camera.mov and cues.json (wall-clock time of each "look at …").
cd "${0:A:h}/../.."
mkdir -p demo/facetest
out=demo/facetest
ffmpeg -y -loglevel error -f avfoundation -framerate 30 -video_size 1280x720 -i "MacBook Air Camera:none" \
  -c:v h264_videotoolbox -b:v 8M "$out/camera.mov" < /dev/null &
cam=$!
sleep 2.5
python3 - "$out/cues.json" <<'EOF'
import json, random, subprocess, sys, time
corners = ['top left', 'top right', 'bottom left', 'bottom right']
order = corners[:] + random.sample(corners, 4) + random.sample(corners, 4)   # first round is the calibration
cues = []
for name in order:
    subprocess.run(['say', '-v', 'Samantha', f'Look at {name}'])
    cues.append({'corner': name.replace(' ', '-'), 't': time.time()})
    time.sleep(2.2)
json.dump(cues, open(sys.argv[1], 'w'), indent=1)
EOF
say -v Samantha "Done."
python3 -c "import time; print(time.time())" > "$out/camEnd.txt"
kill -INT $cam; wait
ls -la demo/facetest
