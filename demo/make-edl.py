"""Builds the edit list for the Remotion video (demo/video/src/edl.json) from the takes and their logs.

Every spoken command is placed where Glance really heard it (the "demo voice … at <time>" lines in the take's
Glance log), so the picture and the Kokoro clips stay in sync. Times below are seconds in the source take
("src") or in the finished video ("out"). Cameras are in screen points: centre x, centre y, visible width.

    python3 demo/make-edl.py terminals5 figma3 figma3b
"""
import json
import re
import subprocess
import sys
from pathlib import Path

DEMO = Path(__file__).resolve().parent
FPS = 30
DUR = json.loads((DEMO / 'audio/durations.json').read_text())
LINES = {l['id']: l['text'] for l in json.loads((DEMO / 'lines.json').read_text())}
FULL = [855, 551, 1710]          # the whole screen between the menu bar and the Dock


def probe(path):
    return float(subprocess.check_output(['ffprobe', '-v', 'error', '-show_entries', 'format=duration', '-of', 'csv=p=0', str(path)]))


class Take:
    """A recorded take: its driver events, when Glance heard each clip, and how driver time maps to video time."""

    def __init__(self, name):
        self.events = json.loads((DEMO / f'takes/{name}.events.json').read_text())
        log = (DEMO / f'takes/{name}.glance.log').read_text(errors='ignore')
        self.heard = [(clip, float(t)) for clip, t in re.findall(r'demo voice: (\w+)\.wav at ([0-9.]+)', log)]
        duration = probe(DEMO / f'takes/{name}.screen.mov')
        start, end = self.events[0]['t'], self.events[-1]['t']
        self.offset = duration - (end - start) - 1.0          # record.sh stops the screen 1 s after the driver ends
        self.start = start

    def src(self, epoch):
        return epoch - self.start + self.offset

    def clip(self, clip_id, nth=0):
        times = [t for c, t in self.heard if c == clip_id]
        return self.src(times[nth])

    def mark(self, name):
        return self.src(next(e['t'] for e in self.events if e.get('name') == name))


class Act:
    def __init__(self, video, chapter):
        self.video, self.chapter = video, chapter
        self.out = 0.0
        self.segments, self.audio, self.captions, self.subtitles, self.cameras = [], [], [], [], []

    def play(self, a, b, speed=1.0, video=None):
        self.segments.append({'kind': 'play', 'src': a, 'out': self.out, 'dur': (b - a) / speed, 'speed': speed,
                              'video': video or self.video})
        self.out += (b - a) / speed

    def hold(self, at, dur, video=None):
        self.segments.append({'kind': 'hold', 'src': at, 'out': self.out, 'dur': dur, 'speed': 1, 'video': video or self.video})
        self.out += dur

    def to_out(self, src, video=None):
        for s in self.segments:
            if s['kind'] == 'play' and s['video'] == (video or self.video) and s['src'] <= src <= s['src'] + s['dur'] * s['speed']:
                return s['out'] + (src - s['src']) / s['speed']
        raise ValueError(f'src {src} is not in a played segment')

    def say(self, line_id, out=None, src=None, caption=True):
        """A narration line (subtitled) at an output time, or at the output time of a source moment."""
        at = out if out is not None else self.to_out(src)
        self.audio.append({'file': f'audio/{line_id}.wav', 'out': at, 'dur': DUR[line_id], 'volume': 1})
        if caption:
            self.subtitles.append({'text': LINES[line_id], 'out': at, 'dur': DUR[line_id]})
        return at + DUR[line_id]

    def command(self, take, clip_id, nth=0):
        """A spoken command: the Kokoro clip where Glance heard it, plus its caption pill."""
        at = self.to_out(take.clip(clip_id, nth))
        self.audio.append({'file': f'audio/{clip_id}.wav', 'out': at, 'dur': DUR[clip_id], 'volume': 1})
        self.captions.append({'text': LINES[clip_id], 'out': at, 'dur': max(DUR[clip_id] + 1.2, 2.4)})

    def camera(self, out, cam, ease=0.8):
        self.cameras.append({'out': out, 'x': cam[0], 'y': cam[1], 'w': cam[2], 'ease': ease})

    def json(self):
        return {'kind': 'screen', 'video': self.video, 'chapter': self.chapter, 'dur': self.out, 'segments': self.segments,
                'audio': self.audio, 'captions': self.captions, 'subtitles': self.subtitles, 'cameras': self.cameras}


def terminals(take_name):
    t = Take(take_name)
    act = Act('terminals.mp4', 'Four terminals, four tasks at once')
    first = t.clip('t01') - 1.6
    act.camera(0, FULL)
    act.hold(first, 5.2)
    act.say('a01', out=0.2)
    act.play(first, t.clip('t02') + 3.6)                       # all four commands, real time
    for c in ['t01', 't06', 't05', 't02']:
        act.command(t, c)
    after = t.clip('t02') + 3.6
    freeze_at = act.out
    act.hold(after, DUR['a02'] + 0.8)                          # the answers on screen while it is explained
    act.say('a02', out=freeze_at + 0.3)
    act.camera(freeze_at + 1.6, [430, 230, 1000])              # the failing test's answer (top left)
    act.camera(freeze_at + 4.6, [1290, 640, 1000])             # the bug found in the code (bottom right)
    act.camera(freeze_at + DUR['a02'] + 0.6, FULL)
    yes = t.clip('t03')
    act.play(after, yes + 1.0)
    act.say('a04', src=yes - 3.1)
    act.command(t, 't03')
    act.camera(act.to_out(yes - 3.4), [430, 700, 1100])        # git, waiting for the yes
    panel = t.mark('panel')
    act.play(yes + 1.0, panel, speed=2.0)
    act.play(panel, panel + 6.4)
    act.camera(act.to_out(panel) + 0.4, [1380, 880, 1000])     # the mascot's task list
    act.say('a05', src=panel + 0.6)
    return act.json()


def figma(take_name, undo_take_name):
    t, u = Take(take_name), Take(undo_take_name)
    act = Act('figma.mp4', 'Inside an app: the exact layer')
    c = t.clip('c01')
    rel = lambda s: c + s                                      # seconds after "Make this button red."
    act.camera(0, FULL)
    act.hold(rel(-2.3), 4.2)                                   # the demo screen, before the pointer moves
    act.say('n02', out=0.2)
    act.play(rel(-2.3), rel(1.6))                              # glide to the button, say it
    act.command(t, 'c01')
    hold = act.out
    act.hold(rel(1.6), DUR['n03'] + 0.6)                       # Figma's outline shows which layer the words go to
    act.say('n03', out=hold + 0.3)
    act.camera(hold + 0.2, [760, 860, 900])
    act.camera(hold + DUR['n03'] + 0.2, FULL)
    act.play(rel(1.6), rel(4.3))
    hold = act.out
    act.hold(rel(4.3), DUR['n04'] + 0.5)                       # the button is still working; next command anyway
    act.say('n04', out=hold + 0.2)
    act.play(rel(4.3), rel(9.7))                               # cards, said while the button turns red
    act.command(t, 'c02')
    hold = act.out
    act.hold(rel(9.7), DUR['n05'] + 0.5)
    act.say('n05', out=hold + 0.2)
    act.camera(hold + 0.2, [820, 700, 1100])                   # red button, cards selected
    act.camera(hold + DUR['n05'] + 0.2, FULL)
    act.play(rel(9.7), rel(30.8))                              # green, the photo, the heading: real time
    act.play(rel(30.8), rel(33.6), speed=2.0)                  # the last task finishing
    for clip in ['c04', 'c05', 'c06']:
        act.command(t, clip)
    act.say('n06', src=rel(24.7))
    act.camera(act.to_out(rel(23.6)), [882, 520, 1100])        # the heading changes, the photo lands
    act.camera(act.to_out(rel(31.0)), FULL)
    panel = t.mark('panel')
    act.play(rel(33.6), panel + 2.6)
    hold = act.out
    act.hold(panel + 2.6, DUR['n07'] + 0.6)                    # every task: "✓ Checked" by the reviewer
    act.say('n07', out=hold + 0.2)
    act.camera(hold - 1.0, [1360, 650, 700], ease=1.2)        # the task panel, top tasks first
    act.camera(hold + 7.5, [1360, 800, 700], ease=6.0)
    undo, U = u.mark('undo'), 'figma-undo.mp4'                # a second take, same screen: Undo on the heading task
    start = act.out
    act.hold(undo - 2.4, 2.2, video=U)
    act.say('n08', out=start + 0.2)
    act.camera(start, [1000, 440, 1450], ease=1.0)
    act.play(undo - 2.4, undo + 5.2, video=U)                  # the click lands on "And undo puts the layer back"
    return act.json()


def card(kind, dur, **extra):
    return {'kind': kind, 'dur': dur, **extra}


def main():
    acts = [
        card('title', DUR['n01'] + 1.4, say='n01'),
        terminals(sys.argv[1] if len(sys.argv) > 1 else 'terminals5'),
        figma(sys.argv[2] if len(sys.argv) > 2 else 'figma3', sys.argv[3] if len(sys.argv) > 3 else 'figma3b'),
        card('architecture', DUR['n09'] + 1.2, say='n09'),
        card('close', DUR['n10'] + 2.6, say='n10'),
    ]
    for a in acts:
        if 'say' in a:
            a['audio'] = [{'file': f"audio/{a['say']}.wav", 'out': 0.6, 'dur': DUR[a['say']], 'volume': 1}]
            a['subtitles'] = [{'text': LINES[a['say']], 'out': 0.6, 'dur': DUR[a['say']]}]
    out = DEMO / 'video/src/edl.json'
    out.parent.mkdir(parents=True, exist_ok=True)
    out.write_text(json.dumps({'fps': FPS, 'acts': acts}, indent=1))
    print(f"{sum(a['dur'] for a in acts):.1f} s total:", ', '.join(f"{a['kind']} {a['dur']:.1f}" for a in acts))


main()
