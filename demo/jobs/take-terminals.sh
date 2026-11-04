# One take of the terminals act: fresh shop state, fresh Glance, the four windows, then a recording with the
# camera while you point with your head and hold Left Option four times.
#   take-terminals.sh <take-name> [seconds]
cd "${0:A:h}/../.."
take=$1; secs=${2:-80}
( cd ~/MetaAICompetition/demo-shop && git reset -q --soft "$(git rev-list --max-parents=0 HEAD)" && git reset -q && git status --short )
zsh demo/jobs/start-glance.sh > /dev/null
zsh demo/jobs/layout-terminals.sh
sleep 3
A=$PWD/demo/audio
printf '%s\n' $A/t01.wav $A/t02.wav $A/t03.wav $A/t04.wav > demo/.voice/queue
zsh demo/jobs/record.sh "$take" "$secs" --camera &
rec=$!
sleep 2.5
say -v Samantha "Recording. Go."
wait $rec
say -v Samantha "Done."
grep -E "demo voice|You said|Glance:" demo/logs/glance.log | tail -12
