import { describe, expect, it } from 'vitest';

import { inOffWindow } from './falWarmer.js';

describe('inOffWindow', () => {
  it('simple window 2→8: off inside, on outside', () => {
    expect(inOffWindow(2, 2, 8)).toBe(true); // start inclusive
    expect(inOffWindow(5, 2, 8)).toBe(true);
    expect(inOffWindow(8, 2, 8)).toBe(false); // end exclusive
    expect(inOffWindow(1, 2, 8)).toBe(false);
    expect(inOffWindow(23, 2, 8)).toBe(false);
  });

  it('wraparound window 22→6', () => {
    expect(inOffWindow(23, 22, 6)).toBe(true);
    expect(inOffWindow(0, 22, 6)).toBe(true);
    expect(inOffWindow(5, 22, 6)).toBe(true);
    expect(inOffWindow(6, 22, 6)).toBe(false);
    expect(inOffWindow(12, 22, 6)).toBe(false);
  });

  it('equal start/end means no off-window', () => {
    expect(inOffWindow(3, 3, 3)).toBe(false);
  });
});
