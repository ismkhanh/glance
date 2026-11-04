# Four Terminal windows in the four corners of the screen, each doing real work in the demo shop: failing tests,
# the API server, uncommitted changes, and the cart code. Safe to run again: it
# first closes the windows it opened last time (and only those).
cd "${0:A:h}/../.."
SHOP=$HOME/MetaAICompetition/demo-shop
PROMPT="export STARSHIP_CONFIG=$PWD/demo/starship-demo.toml; cd $SHOP; clear"
TOP=39; W=855; MID=551; BOTTOM=1062; RIGHT=1710      # points; BOTTOM stops above the Dock

# Last run's windows: stop what runs in them, then close them.
pkill -f 'dev.sh$'; pkill -f 'curl -s localhost:5173'; pkill -f 'node server.js'
ttys=$(osascript -e 'set out to ""' -e 'tell application "Terminal"' -e 'repeat with w in (every window whose name contains "shop —")' \
  -e 'repeat with t in tabs of w' -e 'set out to out & (tty of t) & linefeed' -e 'end repeat' -e 'end repeat' -e 'end tell' -e 'return out' 2>/dev/null)
for t in ${(f)ttys}; do [[ $t == /dev/* ]] && pkill -KILL -t ${t#/dev/}; done
sleep 0.5
osascript -e 'tell application "Terminal" to close (every window whose name contains "shop —")'

# Windows are sized first and given their command after, so the output is drawn at the final size.
osascript <<EOF
on place(title, b, cmd)
  tell application "Terminal"
    activate
    set index of (first window whose name contains title) to 1
    delay 0.4
    tell application "System Events" to tell process "Terminal"
      repeat 4 times
        keystroke "+" using command down
        delay 0.05
      end repeat
    end tell
    delay 0.3
    set bounds of (first window whose name contains title) to b
    delay 0.2
    do script cmd in selected tab of (first window whose name contains title)
  end tell
end place

tell application "Terminal"
  activate
  set miniaturized of (every window whose name contains "session.sh") to true
  set custom title of (do script "$PROMPT") to "shop — tests"
  delay 0.4
  set custom title of (do script "$PROMPT") to "shop — API"
  delay 0.4
  set custom title of (do script "$PROMPT") to "shop — git"
  delay 0.4
  set custom title of (do script "$PROMPT") to "shop — code"
  delay 0.6
end tell
my place("shop — tests", {0, $TOP, $W, $MID}, "clear; node --test 2>&1 | grep -v '^ *at '")
my place("shop — API", {$W, $TOP, $RIGHT, $MID}, "clear; ./dev.sh")
my place("shop — git", {0, $MID, $W, $BOTTOM}, "clear; git status")
my place("shop — code", {$W, $MID, $RIGHT, $BOTTOM}, "clear; cat -n cart.js")
EOF
echo laid out
