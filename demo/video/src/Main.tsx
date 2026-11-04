import React from 'react';
import { AbsoluteFill, Sequence } from 'remotion';
import edl from './edl.json';
import { C } from './theme';
import { ScreenAct, ScreenActData } from './ScreenAct';
import { ArchitectureCard, CardData, CloseCard, TitleCard } from './Cards';

type Act = ScreenActData | CardData;
const acts = edl.acts as unknown as Act[];
const FPS = 30;
const OVERLAP = 0.4;          // acts cross-fade into each other

const starts: number[] = [];
let at = 0;
for (const a of acts) {
  starts.push(at);
  at += a.dur - OVERLAP;
}
export const totalFrames = Math.round((at + OVERLAP) * FPS);

export const Main: React.FC = () => {
  let screens = 0;
  return (
    <AbsoluteFill style={{ background: C.bg }}>
      {acts.map((a, i) => {
        const body = a.kind === 'screen' ? <ScreenAct act={a} n={++screens} />
          : a.kind === 'title' ? <TitleCard card={a} />
          : a.kind === 'architecture' ? <ArchitectureCard card={a} />
          : <CloseCard card={a} />;
        return (
          <Sequence key={i} from={Math.round(starts[i] * FPS)} durationInFrames={Math.round(a.dur * FPS)}>
            {body}
          </Sequence>
        );
      })}
    </AbsoluteFill>
  );
};
