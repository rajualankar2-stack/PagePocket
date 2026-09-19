// Welcome sample: proves the local server serves CSS, JS, JSON and modules.

const counterButton = document.getElementById('counter');
let tapCount = 0;

counterButton.addEventListener('click', () => {
  tapCount += 1;
  counterButton.textContent = `Tapped ${tapCount} time${tapCount === 1 ? '' : 's'}`;
  console.log('Counter tapped', tapCount);
});

// Hue slider drives the swatch via a CSS custom property.
const hueInput = document.getElementById('hue');
const hueValue = document.getElementById('hue-value');
const swatch = document.getElementById('swatch');

function applyHue() {
  const hue = hueInput.value;
  hueValue.textContent = `${hue}°`;
  swatch.style.background = `hsl(${hue} 85% 60%)`;
}

hueInput.addEventListener('input', applyHue);
applyHue();

// ---- Capability checks -------------------------------------------------

function report(name, ok, extra = '') {
  const item = document.createElement('li');
  item.className = ok ? 'pass' : 'fail';
  item.textContent = extra ? `${name} — ${extra}` : name;
  return item;
}

const list = document.getElementById('capabilities');
list.innerHTML = '';

list.appendChild(report('JavaScript', true, 'running'));
list.appendChild(report('CSS custom properties', CSS.supports('color', 'var(--x)'), 'var()'));
list.appendChild(report('Canvas 2D', !!document.createElement('canvas').getContext('2d')));
list.appendChild(report('WebGL', (() => {
  try { return !!document.createElement('canvas').getContext('webgl2'); } catch { return false; }
})(), 'webgl2'));
list.appendChild(report('localStorage', (() => {
  try { localStorage.setItem('__pp', '1'); localStorage.removeItem('__pp'); return true; }
  catch { return false; }
})()));
list.appendChild(report('ES modules', 'noModule' in HTMLScriptElement.prototype));
list.appendChild(report('IntersectionObserver', 'IntersectionObserver' in window));
list.appendChild(report('Web Audio', 'AudioContext' in window || 'webkitAudioContext' in window));

// fetch() against the same origin — the payoff of serving over HTTP.
(async () => {
  try {
    const response = await fetch('data.json', { cache: 'no-store' });
    if (!response.ok) throw new Error(`HTTP ${response.status}`);
    await response.json();
    list.appendChild(report('fetch() same-origin', true, 'data.json ok'));
  } catch (error) {
    list.appendChild(report('fetch() same-origin', false, error.message));
    console.warn('fetch() check failed:', error.message);
  }
})();

// ---- Explicit fetch button ---------------------------------------------

const loadButton = document.getElementById('load-json');
const jsonOutput = document.getElementById('json-output');

loadButton.addEventListener('click', async () => {
  loadButton.textContent = 'Loading…';
  try {
    const response = await fetch('data.json?t=' + Date.now());
    const data = await response.json();
    jsonOutput.hidden = false;
    jsonOutput.textContent = JSON.stringify(data, null, 2);
    console.log('Loaded data.json', data);
  } catch (error) {
    jsonOutput.hidden = false;
    jsonOutput.textContent = 'Failed: ' + error.message;
    console.error('Could not load data.json:', error);
  } finally {
    loadButton.textContent = 'Load data.json';
  }
});

console.log('Welcome sample ready. Tap the button, then open the Console from the toolbar.');
