# The terminals act, played by the driver (pointer + talk key + Kokoro clips): fresh shop, fresh Glance,
# the four windows, then a screen recording of demo/scenes/terminals.json.
#   take-terminals-driven.sh <take-name>
cd "${0:A:h}/../.."
( cd ~/MetaAICompetition/demo-shop && git reset -q --soft "$(git rev-list --max-parents=0 HEAD)" && git reset -q && git status --short )
zsh demo/jobs/start-glance.sh > /dev/null
zsh demo/jobs/layout-terminals.sh
sleep 3
zsh demo/jobs/record.sh "$1" demo/scenes/terminals.json
grep -E "demo voice|You said|Glance:|Target|→ " demo/logs/glance.log | tail -24
