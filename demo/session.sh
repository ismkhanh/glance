#!/bin/zsh
# Demo recording session. Run it in Terminal.app, which already has the permissions Glance needs
# (Accessibility, Input Monitoring, Microphone, Camera, Screen Recording):
#
#   zsh demo/session.sh        (from the Glance folder)
#
# It runs the job scripts that appear in demo/.jobs, one at a time, with Terminal's permissions, and logs each
# to demo/logs. Leave the window open; Ctrl+C stops it.
cd "${0:A:h}/.."
mkdir -p demo/.jobs/done demo/logs demo/.voice demo/takes
print "Glance demo session in $PWD. Leave this window open (Ctrl+C stops it)."
while true; do
  for job in demo/.jobs/*.sh(N); do
    name=${job:t:r}
    print -n "▶ $name … "
    zsh "$job" > "demo/logs/$name.log" 2>&1
    print "exit $?"
    mv -f "$job" demo/.jobs/done/
  done
  sleep 0.3
done
