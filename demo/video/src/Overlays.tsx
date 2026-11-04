import React from 'react';
import { Easing, interpolate, spring, useCurrentFrame, useVideoConfig } from 'remotion';
import { C, font } from './theme';

export type Timed = { text: string; out: number; dur: number };

/** Fades a timed item in and out; null when it is not on screen. */
function useShown(item: Timed, fadeIn = 0.25, fadeOut = 0.3) {
  const frame = useCurrentFrame();
  const { fps } = useVideoConfig();
  const t = frame / fps;
  if (t < item.out || t > item.out + item.dur + fadeOut) return null;
  const a = interpolate(t, [item.out, item.out + fadeIn], [0, 1], { extrapolateRight: 'clamp' });
  const b = interpolate(t, [item.out + item.dur, item.out + item.dur + fadeOut], [1, 0], { extrapolateLeft: 'clamp' });
  return { opacity: Math.min(a, b), age: t - item.out };
}

/** Narration, written out at the bottom (many people watch with the sound off). */
export const Subtitle: React.FC<{ item: Timed }> = ({ item }) => {
  const s = useShown(item);
  if (!s) return null;
  return (
    <div style={{ position: 'absolute', left: 0, right: 0, bottom: 42, display: 'flex', justifyContent: 'center', opacity: s.opacity }}>
      <div style={{
        maxWidth: 1480, padding: '14px 26px', borderRadius: 14, background: 'rgba(8, 7, 16, 0.78)',
        color: C.text, fontFamily: font, fontSize: 33, lineHeight: 1.35, textAlign: 'center', fontWeight: 400,
      }}>{item.text}</div>
    </div>
  );
};

/** What the user said into Glance (a Kokoro clip), as a pill with a mic. */
export const CommandPill: React.FC<{ item: Timed }> = ({ item }) => {
  const { fps } = useVideoConfig();
  const s = useShown(item, 0.15, 0.35);
  if (!s) return null;
  const pop = spring({ frame: Math.round(s.age * fps), fps, config: { damping: 14, stiffness: 180 } });
  return (
    <div style={{ position: 'absolute', left: 0, right: 0, bottom: 150, display: 'flex', justifyContent: 'center', opacity: s.opacity }}>
      <div style={{
        transform: `scale(${0.85 + 0.15 * pop})`, display: 'flex', alignItems: 'center', gap: 16, padding: '16px 30px',
        borderRadius: 999, background: `linear-gradient(90deg, ${C.violet}, ${C.magenta})`, color: 'white',
        fontFamily: font, fontSize: 40, fontWeight: 600, boxShadow: '0 12px 40px rgba(124, 92, 255, 0.45)',
      }}>
        <Mic />
        <span>“{item.text.replace(/\.$/, '')}”</span>
      </div>
    </div>
  );
};

const Mic: React.FC = () => (
  <svg width="34" height="34" viewBox="0 0 24 24" fill="none" stroke="white" strokeWidth="2" strokeLinecap="round">
    <rect x="9" y="3" width="6" height="11" rx="3" fill="white" />
    <path d="M5 11a7 7 0 0 0 14 0M12 18v3" />
  </svg>
);

export const Chapter: React.FC<{ n: number; text: string }> = ({ n, text }) => {
  const frame = useCurrentFrame();
  const { fps } = useVideoConfig();
  const o = interpolate(frame / fps, [0.2, 0.7, 4.5, 5.2], [0, 1, 1, 0], { extrapolateLeft: 'clamp', extrapolateRight: 'clamp' });
  return (
    <div style={{ position: 'absolute', top: 36, left: 40, opacity: o, display: 'flex', gap: 14, alignItems: 'center',
      padding: '12px 22px', borderRadius: 999, background: 'rgba(8, 7, 16, 0.8)', color: C.text, fontFamily: font, fontSize: 28 }}>
      <span style={{ color: C.violet, fontWeight: 800 }}>{n}</span>
      <span style={{ fontWeight: 600 }}>{text}</span>
    </div>
  );
};

export const SpeedBadge: React.FC<{ speed: number }> = ({ speed }) => (
  <div style={{ position: 'absolute', top: 36, right: 40, padding: '10px 20px', borderRadius: 999, background: 'rgba(8, 7, 16, 0.8)',
    color: C.text, fontFamily: font, fontSize: 26, fontWeight: 600 }}>⏩ {speed}× speed</div>
);

/** Glance's mascot: a round friend with one big eye that looks around. */
export const Mascot: React.FC<{ size: number; look?: number }> = ({ size, look = 0 }) => {
  const frame = useCurrentFrame();
  const t = frame / 30 + look;
  const dx = Math.sin(t * 0.9) * size * 0.09;
  const dy = Math.cos(t * 1.3) * size * 0.05;
  const blink = (Math.floor(t * 10) % 37) === 0 ? 0.15 : 1;
  return (
    <div style={{ width: size, height: size, borderRadius: '50%', background: `radial-gradient(circle at 35% 30%, #A68BFF, ${C.violet} 55%, #5A2FD6)`,
      boxShadow: `0 0 ${size * 0.4}px rgba(124, 92, 255, 0.55)`, display: 'flex', alignItems: 'center', justifyContent: 'center' }}>
      <div style={{ width: size * 0.5, height: size * 0.5 * blink, borderRadius: '50%', background: 'white', display: 'flex',
        alignItems: 'center', justifyContent: 'center', overflow: 'hidden' }}>
        <div style={{ width: size * 0.22, height: size * 0.22, borderRadius: '50%', background: '#1B1530',
          transform: `translate(${dx}px, ${dy}px)` }} />
      </div>
    </div>
  );
};

export const easeInOut = Easing.bezier(0.45, 0, 0.2, 1);
