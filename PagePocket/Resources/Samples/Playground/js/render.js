// Canvas renderer, imported as an ES module by main.js.

import { rosePoints, TAU } from './geometry.js';

export class RoseRenderer {
  constructor(canvas) {
    this.canvas = canvas;
    this.ctx = canvas.getContext('2d');
    this.phase = 0;
    this.speed = 1;
    this.running = true;
    this.dpr = Math.min(window.devicePixelRatio || 1, 3);

    this.resize();
    window.addEventListener('resize', () => this.resize());
  }

  resize() {
    const rect = this.canvas.getBoundingClientRect();
    if (rect.width === 0) return;
    this.canvas.width = Math.round(rect.width * this.dpr);
    this.canvas.height = Math.round(rect.height * this.dpr);
  }

  setSpeed(value) {
    this.speed = value;
  }

  start() {
    const frame = () => {
      if (!this.running) return;
      this.phase += 0.012 * this.speed;
      this.draw();
      requestAnimationFrame(frame);
    };
    requestAnimationFrame(frame);
  }

  stop() {
    this.running = false;
  }

  draw() {
    const { ctx } = this;
    const { width, height } = this.canvas;

    ctx.clearRect(0, 0, width, height);

    const cx = width / 2;
    const cy = height / 2;
    const scale = Math.min(width, height) * 0.38;
    const petals = 3 + Math.sin(this.phase * 0.5) * 2;

    ctx.save();
    ctx.translate(cx, cy);

    // Three stacked rose curves at different phases.
    for (let layer = 0; layer < 3; layer += 1) {
      const points = rosePoints(220, petals, scale * (1 - layer * 0.22), this.phase + layer * 0.4);

      const hue = (this.phase * 40 + layer * 60) % 360;
      ctx.beginPath();
      points.forEach((point, index) => {
        if (index === 0) ctx.moveTo(point.x, point.y);
        else ctx.lineTo(point.x, point.y);
      });
      ctx.closePath();

      ctx.strokeStyle = `hsl(${hue} 90% 65% / ${0.85 - layer * 0.22})`;
      ctx.lineWidth = 2.5 * this.dpr;
      ctx.stroke();
    }

    // Orbiting dot, so motion is obvious even in a still screenshot.
    const orbitRadius = scale * 1.05;
    const dotX = Math.cos(this.phase * 2) * orbitRadius;
    const dotY = Math.sin(this.phase * 2) * orbitRadius;
    ctx.beginPath();
    ctx.arc(dotX, dotY, 5 * this.dpr, 0, TAU);
    ctx.fillStyle = '#34d3ee';
    ctx.fill();

    ctx.restore();
  }
}
