import React from 'react';
import { AbsoluteFill, Audio, Sequence, interpolate, spring, staticFile, useCurrentFrame, useVideoConfig } from 'remotion';
import { C, font, mono } from './theme';
import { Mascot, Subtitle, Timed } from './Overlays';
import type { Sound } from './ScreenAct';

export type CardData = { kind: 'title' | 'architecture' | 'close'; dur: number; audio: Sound[]; subtitles: Timed[] };

const Backdrop: React.FC<{ dur: number; children: React.ReactNode }> = ({ dur, children }) => {
  const frame = useCurrentFrame();
  const { fps } = useVideoConfig();
  const t = frame / fps;
  const fade = interpolate(t, [0, 0.4, dur - 0.4, dur], [0, 1, 1, 0], { extrapolateLeft: 'clamp', extrapolateRight: 'clamp' });
  return (
    <AbsoluteFill style={{ opacity: fade, background: `radial-gradient(ellipse at 50% 35%, ${C.bg2}, ${C.bg} 70%)`, fontFamily: font, color: C.text }}>
      {children}
    </AbsoluteFill>
  );
};

const Sounds: React.FC<{ card: CardData }> = ({ card }) => {
  const { fps } = useVideoConfig();
  return (
    <>
      {card.audio.map((a, i) => (
        <Sequence key={i} from={Math.round(a.out * fps)} durationInFrames={Math.round((a.dur + 0.3) * fps)} layout="none">
          <Audio src={staticFile(a.file)} volume={a.volume} />
        </Sequence>
      ))}
      {card.subtitles.map((s, i) => <Subtitle key={i} item={s} />)}
    </>
  );
};

/** Rises into place `at` seconds into the card. */
const Rise: React.FC<{ at: number; children: React.ReactNode; style?: React.CSSProperties }> = ({ at, children, style }) => {
  const frame = useCurrentFrame();
  const { fps } = useVideoConfig();
  const p = spring({ frame: frame - Math.round(at * fps), fps, config: { damping: 16, stiffness: 120 } });
  return <div style={{ opacity: p, transform: `translateY(${(1 - p) * 24}px)`, ...style }}>{children}</div>;
};

const Models: React.FC = () => (
  <div style={{ display: 'flex', gap: 14, justifyContent: 'center' }}>
    {['Muse Spark', 'Muse Voice Transcribe', 'Muse Image'].map((m) => (
      <div key={m} style={{ padding: '10px 20px', borderRadius: 999, border: `1.5px solid ${C.line}`, background: 'rgba(124, 92, 255, 0.12)',
        fontSize: 26, fontWeight: 600 }}>{m}</div>
    ))}
  </div>
);

export const TitleCard: React.FC<{ card: CardData }> = ({ card }) => (
  <Backdrop dur={card.dur}>
    <AbsoluteFill style={{ alignItems: 'center', justifyContent: 'center', gap: 34, paddingBottom: 120 }}>
      <Rise at={0.1}><Mascot size={170} /></Rise>
      <Rise at={0.35}><div style={{ fontSize: 150, fontWeight: 800, letterSpacing: -4 }}>Glance</div></Rise>
      <Rise at={0.6}><div style={{ fontSize: 50, fontWeight: 600, color: C.dim }}>Point at it. Say it.</div></Rise>
      <Rise at={1.0}><Models /></Rise>
    </AbsoluteFill>
    <Rise at={1.4} style={{ position: 'absolute', top: 40, left: 0, right: 0, textAlign: 'center', fontSize: 22, color: C.dim }}>
      Recorded live on a Mac. Spoken commands use a Kokoro voice and go through Glance's real speech pipeline. Sped-up waits are marked.
    </Rise>
    <Sounds card={card} />
  </Backdrop>
);

const Box: React.FC<{ at: number; title: string; body: string; accent?: string; w?: number }> = ({ at, title, body, accent = C.violet, w = 400 }) => (
  <Rise at={at} style={{ width: w, padding: '20px 24px', borderRadius: 18, background: C.card, border: `1.5px solid ${C.line}`,
    borderTop: `5px solid ${accent}` }}>
    <div style={{ fontSize: 30, fontWeight: 800, marginBottom: 8 }}>{title}</div>
    <div style={{ fontSize: 22, color: C.dim, lineHeight: 1.35 }}>{body}</div>
  </Rise>
);

const Arrow: React.FC<{ at: number }> = ({ at }) => (
  <Rise at={at} style={{ fontSize: 44, color: C.violet, alignSelf: 'center' }}>→</Rise>
);

export const ArchitectureCard: React.FC<{ card: CardData }> = ({ card }) => (
  <Backdrop dur={card.dur}>
    <AbsoluteFill style={{ padding: '70px 90px', gap: 34 }}>
      <Rise at={0.1}><div style={{ fontSize: 46, fontWeight: 800 }}>How Glance works</div></Rise>
      <div style={{ display: 'flex', gap: 18 }}>
        <Box at={0.4} title="You" body="Point at a window or a layer, hold ⌥, speak. Move on right away." accent={C.green} w={330} />
        <Arrow at={0.8} />
        <Box at={1.0} title="Muse Voice Transcribe" body="Speech to text in real time, while you hold the key." w={380} />
        <Arrow at={4.4} />
        <Box at={4.6} title="Muse Spark, per task" body="Reads the window you pointed at (its text, the element, a picture) and acts through tools." w={460} />
      </div>
      <div style={{ display: 'flex', gap: 18, marginLeft: 348 }}>
        <Box at={7.0} title="Tasks side by side" body="Each command is its own task, with its own card and a line in the mascot's list." accent={C.magenta} w={430} />
        <Arrow at={8.2} />
        <Box at={8.4} title="Terminal · Chrome · any app" body={'Typing, keys, tabs, clicks. Risky actions wait for your "yes".'} accent={C.magenta} w={430} />
      </div>
      <Rise at={10.2} style={{ marginLeft: 348, padding: '20px 26px', borderRadius: 18, border: `1.5px dashed ${C.line}`, display: 'flex', gap: 18, alignItems: 'center' }}>
        <div style={{ fontSize: 30, fontWeight: 800, width: 150 }}>Figma</div>
        <div style={{ fontFamily: mono, fontSize: 24, color: C.text, lineHeight: 1.6 }}>
          plugin ⇄ orchestrator → workers <span style={{ color: C.dim }}>(Muse Spark, in parallel)</span><br />
          {'            '}→ Muse Image <span style={{ color: C.dim }}>paints</span> → reviewer <span style={{ color: C.dim }}>(rules + Muse Spark)</span> → done · retry · undo
        </div>
      </Rise>
    </AbsoluteFill>
    <Sounds card={card} />
  </Backdrop>
);

export const CloseCard: React.FC<{ card: CardData }> = ({ card }) => (
  <Backdrop dur={card.dur}>
    <AbsoluteFill style={{ alignItems: 'center', justifyContent: 'center', gap: 30, paddingBottom: 130 }}>
      <Rise at={0.1}><Mascot size={130} look={2} /></Rise>
      <Rise at={0.3}><div style={{ fontSize: 120, fontWeight: 800, letterSpacing: -3 }}>Glance</div></Rise>
      <Rise at={0.5}><div style={{ fontSize: 48, fontWeight: 600, color: C.dim }}>Point at it. Say it.</div></Rise>
      <Rise at={1.6}><div style={{ fontSize: 30, color: C.text }}>Works with any pointer: mouse · trackpad · macOS Head Pointer · eye trackers</div></Rise>
      <Rise at={2.2}><Models /></Rise>
    </AbsoluteFill>
    <Sounds card={card} />
  </Backdrop>
);
