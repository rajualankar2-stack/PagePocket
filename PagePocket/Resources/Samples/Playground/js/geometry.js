// Pure geometry helpers, imported as an ES module.

export const TAU = Math.PI * 2;

export function lerp(a, b, t) {
  return a + (b - a) * t;
}

export function clamp(value, min, max) {
  return Math.min(max, Math.max(min, value));
}

/** Distance from a point to the origin. */
export function radius(x, y) {
  return Math.hypot(x, y);
}

/**
 * Points on a rose curve, r = cos(k·θ).
 * Used by the canvas renderer to draw a smoothly morphing shape.
 */
export function rosePoints(count, k, scale, phase) {
  const points = [];
  for (let i = 0; i < count; i += 1) {
    const theta = (i / count) * TAU;
    const r = Math.cos(k * theta + phase) * scale;
    points.push({ x: Math.cos(theta) * r, y: Math.sin(theta) * r });
  }
  return points;
}

/** A short human-readable summary, used to prove the import executed. */
export function describe() {
  return `geometry module loaded (${Object.keys({ lerp, clamp, radius, rosePoints }).length} exports)`;
}
