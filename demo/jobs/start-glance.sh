# Restarts Glance with the demo voice folder. Its brain starts with it; both log to demo/logs/glance.log.
cd "${0:A:h}/../.."
pkill -f '.build/release/Glance' && sleep 1
lsof -tiTCP:47800 -sTCP:LISTEN | xargs kill 2>/dev/null && sleep 0.5
rm -f demo/.voice/next demo/.voice/queue
GLANCE_DEMO_VOICE=$PWD/demo/.voice nohup script -q -F demo/logs/glance.log .build/release/Glance "$@" < /dev/null > /dev/null 2>&1 &
sleep 4
tail -20 demo/logs/glance.log
