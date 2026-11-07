import React from 'react';
import {Audio, Composition, interpolate, staticFile} from 'remotion';
import {Launch, Title} from './Launch';
import {Launch as LaunchGrid} from './LaunchGrid';
import {Concept, CONCEPTS} from './TitleConcepts';
import {beat, DROP, FPS, SONG_START, TOTAL_FRAMES} from './timing';

/** Just the opening (title over the grid, with its music), for comparing title concepts. */
const TitleOnly: React.FC<{concept: Concept}> = ({concept}) => (
  <>
    <Audio
      src={staticFile('audio/parallel-jalebi.flac')}
      trimBefore={Math.round(SONG_START * FPS)}
      volume={(f) => interpolate(f, [0, 45, beat(DROP) - 20, beat(DROP)], [0, 1, 1, 0], {extrapolateLeft: 'clamp', extrapolateRight: 'clamp'})}
    />
    <Title concept={concept} />
  </>
);

export const Root: React.FC = () => (
  <>
    <Composition id="Launch" component={Launch} durationInFrames={TOTAL_FRAMES} fps={FPS} width={1920} height={1080} />
    {/* The v5 edit (every look at once, before the zoom-out opening), for comparison. */}
    <Composition id="Launch-grid-opening" component={LaunchGrid} durationInFrames={TOTAL_FRAMES} fps={FPS} width={1920} height={1080} />
    {CONCEPTS.map((concept) => (
      <Composition
        key={concept}
        id={`Title-${concept}`}
        component={TitleOnly}
        defaultProps={{concept}}
        durationInFrames={beat(DROP)}
        fps={FPS}
        width={1920}
        height={1080}
      />
    ))}
  </>
);
