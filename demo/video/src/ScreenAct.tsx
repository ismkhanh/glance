import React from 'react';
import { AbsoluteFill, Audio, Freeze, OffthreadVideo, Sequence, interpolate, staticFile, useCurrentFrame, useVideoConfig } from 'remotion';
import { C } from './theme';
import { Chapter, CommandPill, SpeedBadge, Subtitle, Timed, easeInOut } from './Overlays';

// The recorded screen, in points (the takes are Retina: 2 pixels per point).
const SCREEN_W = 1710;
const SCREEN_H = 1112;

export type Segment = { kind: 'play' | 'hold'; src: number; out: number; dur: number; speed: number; video?: string };
export type Camera = { out: number; x: number; y: number; w: number; ease: number };
export type Sound = { file: string; out: number; dur: number; volume: number };
export type ScreenActData = {
  kind: 'screen'; video: string; chapter: string; dur: number; segments: Segment[]; audio: Sound[];
  captions: Timed[]; subtitles: Timed[]; cameras: Camera[];
};

/** Where the camera is at time t: each keyframe glides from wherever the camera was, over `ease` seconds. */
function cameraAt(cams: Camera[], t: number) {
  let { x, y, w } = cams[0];
  for (const k of cams.slice(1)) {
    if (t <= k.out) break;
    const p = easeInOut(Math.min(1, (t - k.out) / k.ease));
    x += (k.x - x) * p;
    y += (k.y - y) * p;
    w += (k.w - w) * p;
  }
  // Never show past the edges of the screen.
  const halfW = w / 2;
  const halfH = (w * 1080) / 1920 / 2;
  x = Math.min(Math.max(x, halfW), SCREEN_W - halfW);
  y = Math.min(Math.max(y, halfH), SCREEN_H - halfH);
  return { x, y, w };
}

export const ScreenAct: React.FC<{ act: ScreenActData; n: number }> = ({ act, n }) => {
  const frame = useCurrentFrame();
  const { fps, width, height } = useVideoConfig();
  const t = frame / fps;
  const cam = cameraAt(act.cameras, t);
  const scale = width / cam.w;
  const fast = act.segments.find((s) => s.speed !== 1 && t >= s.out && t < s.out + s.dur);
  const fade = interpolate(t, [0, 0.4, act.dur - 0.4, act.dur], [0, 1, 1, 0], { extrapolateLeft: 'clamp', extrapolateRight: 'clamp' });

  return (
    <AbsoluteFill style={{ background: C.bg, opacity: fade }}>
      <div style={{ position: 'absolute', width: SCREEN_W * scale, height: SCREEN_H * scale,
        left: width / 2 - cam.x * scale, top: height / 2 - cam.y * scale }}>
        {act.segments.map((s, i) => {
          const video = <OffthreadVideo src={staticFile(s.video ?? act.video)} trimBefore={Math.round(s.src * fps)} playbackRate={s.speed} muted
            style={{ width: '100%', height: '100%' }} />;
          return (
            <Sequence key={i} from={Math.round(s.out * fps)} durationInFrames={Math.max(1, Math.round(s.dur * fps))} layout="none">
              <div style={{ position: 'absolute', inset: 0 }}>{s.kind === 'hold' ? <Freeze frame={0}>{video}</Freeze> : video}</div>
            </Sequence>
          );
        })}
      </div>
      {act.audio.map((a, i) => (
        <Sequence key={`a${i}`} from={Math.round(a.out * fps)} durationInFrames={Math.round((a.dur + 0.3) * fps)} layout="none">
          <Audio src={staticFile(a.file)} volume={a.volume} />
        </Sequence>
      ))}
      <Chapter n={n} text={act.chapter} />
      {fast && <SpeedBadge speed={fast.speed} />}
      {act.captions.map((c, i) => <CommandPill key={`c${i}`} item={c} />)}
      {act.subtitles.map((s, i) => <Subtitle key={`s${i}`} item={s} />)}
    </AbsoluteFill>
  );
};
