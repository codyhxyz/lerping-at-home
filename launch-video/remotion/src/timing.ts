// Beat grid for Four Tet — "Parallel Jalebi", measured from the file
// (audio/beats.json): 133.000 BPM, first downbeat at 0.0240 s (the first sound
// in the file starts at 0.0253 s), 8-bar phrases with a fill in every 8th bar.
// The breakdown runs bars 79–95; the kick comes back on bar 96 at 173.257 s.
// The video opens 4 bars before that drop.
//
// The kick is syncopated (garage-style, 16th-note percussion between hits), so
// a naive onset fit locks half a beat late, onto each kick's decay. 0.0240 was
// checked bar by bar: the kick band jumps 3–5x exactly on each downbeat.
export const FPS = 60;
export const BPM = 133;
export const FIRST_BEAT = 0.024;
export const START_BAR = 92;

export const SECONDS_PER_BEAT = 60 / BPM;
export const SONG_START = FIRST_BEAT + START_BAR * 4 * SECONDS_PER_BEAT;

/** Frame (in the video) of beat n, counted from the first frame of the video. */
export const beat = (n: number) => Math.round(n * SECONDS_PER_BEAT * FPS);

import picks from './picks.json';

export const TITLE_BEATS = 16; // 4 bars of breakdown
// The montage is as long as its shots. 64 beats = 16 bars = two 8-bar phrases,
// so the closing card lands on the next phrase; keep the total a multiple of 32.
export const MONTAGE_BEATS = picks.montage.reduce((sum, shot) => sum + shot.beats, 0);
export const CLOSING_BEATS = 16; // 4 bars

export const DROP = TITLE_BEATS;
export const CLOSING = TITLE_BEATS + MONTAGE_BEATS;
export const TOTAL_BEATS = CLOSING + CLOSING_BEATS;
export const TOTAL_FRAMES = beat(TOTAL_BEATS) + 30;
