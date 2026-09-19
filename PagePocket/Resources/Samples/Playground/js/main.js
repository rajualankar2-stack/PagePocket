// Entry point for the Playground sample.
// Importing modules here proves the local server sends a JavaScript MIME type.

import { describe, rosePoints } from './geometry.js';
import { RoseRenderer } from './render.js';

const moduleDot = document.getElementById('module-dot');
const moduleResult = document.getElementById('module-result');

try {
  // Touch the imports so a tree-shaker or a load failure cannot pass silently.
  const sample = rosePoints(8, 3, 100, 0);
  moduleResult.textContent =
    `✓ ${describe()}\n✓ render module loaded (RoseRenderer)\n✓ rosePoints() returned ${sample.length} points`;
  moduleResult.classList.add('ok');
  moduleDot.classList.add('ok');
  console.log('ES modules loaded successfully');
} catch (error) {
  moduleResult.textContent = `✕ Module loading failed: ${error.message}`;
  moduleResult.classList.add('bad');
  moduleDot.classList.add('bad');
  console.error('Module failure:', error);
}

// ---- Canvas ------------------------------------------------------------

const canvas = document.getElementById('stage');
const renderer = new RoseRenderer(canvas);

// Draw one frame immediately so a screenshot taken instantly still shows art.
renderer.draw();

// Under automated UI tests, continuous animation makes accessibility snapshots
// go stale between a query and the read. Keep the frame, skip the motion.
const underTest = new URLSearchParams(location.search).has('static')
  || navigator.webdriver === true;

if (!underTest) {
  renderer.start();
}

document.getElementById('canvas-dot').classList.add('ok');

document.getElementById('speed').addEventListener('input', (event) => {
  renderer.setSpeed(Number(event.target.value) / 100);
});

// Pause when the page is hidden to avoid burning CPU in the background.
document.addEventListener('visibilitychange', () => {
  if (document.hidden) {
    renderer.stop();
  } else if (!renderer.running) {
    renderer.running = true;
    renderer.start();
  }
});

// ---- Web Worker --------------------------------------------------------

const workerDot = document.getElementById('worker-dot');
const workerResult = document.getElementById('worker-result');
const runWorkerButton = document.getElementById('run-worker');

runWorkerButton.addEventListener('click', () => {
  runWorkerButton.disabled = true;
  workerResult.textContent = 'Starting worker…';
  workerResult.classList.remove('ok', 'bad');
  workerDot.classList.remove('ok', 'bad');
  workerDot.classList.add('busy');

  // Inline worker via Blob: no extra file needed, and it still runs off-thread.
  const source = `
    self.onmessage = function (event) {
      const limit = event.data.limit;
      const primes = [];
      for (let n = 2; n <= limit; n += 1) {
        let isPrime = true;
        for (let d = 2; d * d <= n; d += 1) {
          if (n % d === 0) { isPrime = false; break; }
        }
        if (isPrime) primes.push(n);
        if (n % 20000 === 0) {
          self.postMessage({ type: 'progress', checked: n, limit: limit, found: primes.length });
        }
      }
      self.postMessage({ type: 'done', count: primes.length, largest: primes[primes.length - 1] });
    };
  `;

  const blob = new Blob([source], { type: 'text/javascript' });
  const workerURL = URL.createObjectURL(blob);

  let worker;
  try {
    worker = new Worker(workerURL);
  } catch (error) {
    workerResult.textContent = `✕ Workers unavailable: ${error.message}`;
    workerResult.classList.add('bad');
    workerDot.classList.remove('busy');
    workerDot.classList.add('bad');
    runWorkerButton.disabled = false;
    return;
  }

  worker.onmessage = (event) => {
    const data = event.data;
    if (data.type === 'progress') {
      const percent = Math.round((data.checked / data.limit) * 100);
      workerResult.textContent = `Working… ${percent}% (${data.found} primes so far)`;
      return;
    }

    workerResult.textContent =
      `✓ Worker finished\n✓ ${data.count} primes below 300,000\n✓ largest: ${data.largest}`;
    workerResult.classList.add('ok');
    workerDot.classList.remove('busy');
    workerDot.classList.add('ok');
    runWorkerButton.disabled = false;
    worker.terminate();
    URL.revokeObjectURL(workerURL);
    console.log('Worker finished:', data);
  };

  worker.onerror = (error) => {
    workerResult.textContent = `✕ Worker error: ${error.message}`;
    workerResult.classList.add('bad');
    workerDot.classList.remove('busy');
    workerDot.classList.add('bad');
    runWorkerButton.disabled = false;
    worker.terminate();
    URL.revokeObjectURL(workerURL);
  };

  worker.postMessage({ limit: 300000 });
  console.log('Worker started');
});

// ---- localStorage ------------------------------------------------------

const storageResult = document.getElementById('storage-result');

function updateStorage() {
  let visits = 0;
  try {
    visits = Number(localStorage.getItem('playground.visits') || '0') + 1;
    localStorage.setItem('playground.visits', String(visits));
    storageResult.textContent =
      `✓ localStorage works\n✓ this page has been opened ${visits} time${visits === 1 ? '' : 's'}\n` +
      `✓ reload to watch it increase`;
    storageResult.classList.add('ok');
  } catch (error) {
    storageResult.textContent =
      `✕ localStorage unavailable: ${error.message}\n` +
      `(This is why PagePocket serves documents over http:// instead of file://.)`;
    storageResult.classList.add('bad');
  }
}

updateStorage();

document.getElementById('reset-storage').addEventListener('click', () => {
  try {
    localStorage.removeItem('playground.visits');
  } catch { /* nothing to clear */ }
  updateStorage();
});

console.log('Playground ready — modules, worker and canvas all initialised.');
