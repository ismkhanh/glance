# The Figma act, played by the driver: fresh Glance, a fresh demo screen (Glance Bridge → Build demo screen),
# then a screen recording of demo/scenes/figma.json.
#   take-figma.sh <take-name> [scene.json]
cd "${0:A:h}/../.."
zsh demo/jobs/start-glance.sh > /dev/null
sleep 4
grep -q "Figma:" demo/logs/glance.log || sleep 4
zsh demo/jobs/drive.sh demo/scenes/figma-setup.json
zsh demo/jobs/record.sh "$1" "${2:-demo/scenes/figma.json}"
grep -E "demo voice|You said|\[brain\]|Question|all tasks" demo/logs/glance.log | tail -40
