import assert from 'node:assert/strict';
import { mkdir, writeFile } from 'node:fs/promises';

// Connect only to a separate headless browser with its own profile.
const endpoint = process.argv[2];
if (!endpoint) throw new Error('Usage: node web/tests/layout-browser.mjs <CDP endpoint> [fixture URL]');
const fixture = process.argv[3] ?? 'http://127.0.0.1:5178/tests/fixture.html?controls&layout';
const tab = await (await fetch(`${endpoint}/json/new?${encodeURIComponent(fixture)}`, { method: 'PUT' })).json();
const socket = new WebSocket(tab.webSocketDebuggerUrl);
await new Promise((resolve, reject) => { socket.onopen = resolve; socket.onerror = reject; });
let sequence = 0;
const pending = new Map(), errors = [], failures = [];
socket.onmessage = event => {
  const message = JSON.parse(event.data);
  if (message.method === 'Runtime.exceptionThrown') errors.push(message.params.exceptionDetails.text);
  if (message.method === 'Runtime.consoleAPICalled' && message.params.type === 'error') errors.push(message.params.args.map(value => value.value ?? value.description).join(' '));
  if (!message.id) return;
  const handler = pending.get(message.id); pending.delete(message.id);
  if (message.error) handler.reject(new Error(message.error.message)); else handler.resolve(message.result);
};
function cdp(method, params = {}) {
  return new Promise((resolve, reject) => { const id = ++sequence; pending.set(id, { resolve, reject }); socket.send(JSON.stringify({ id, method, params })); });
}
async function evaluate(expression) {
  const result = await cdp('Runtime.evaluate', { expression, returnByValue: true, awaitPromise: true });
  if (result.exceptionDetails) throw new Error(result.exceptionDetails.exception?.description ?? result.exceptionDetails.text);
  return result.result.value;
}
const pause = ms => new Promise(resolve => setTimeout(resolve, ms));
async function until(expression) {
  for (let index = 0; index < 50; index++) { if (await evaluate(expression)) return; await pause(100); }
  throw new Error(`UI did not reach: ${expression}`);
}
async function click(selector, text) {
  await evaluate(`(() => { const el = [...document.querySelectorAll(${JSON.stringify(selector)})].find(el => el.getClientRects().length && ${text === undefined ? 'true' : `el.textContent.trim() === ${JSON.stringify(text)}`}); if (!el || el.disabled) throw new Error('Clickable control not found: ' + ${JSON.stringify(text ?? selector)}); el.click(); })()`);
  await pause(180); await until(`document.querySelector('.avm')?.getAttribute('aria-busy') === 'false'`);
}
function check(value, message) { if (!value) failures.push(message); }
async function measure(name, width, height) {
  await cdp('Emulation.setDeviceMetricsOverride', { width, height, deviceScaleFactor: 1, mobile: false });
  await evaluate(`document.querySelector('#fixture-controls').style.display = 'none'; document.activeElement?.blur(); window.scrollTo(0,0)`);
  await pause(160);
  const metrics = await evaluate(`(() => {
    const rect = el => { const r = el.getBoundingClientRect(); return { x:r.x, y:r.y, width:r.width, height:r.height, right:r.right }; };
    const list = document.querySelector('.part-list'), detail = document.querySelector('.material-detail');
    const elements = [...document.querySelectorAll('.part-row, .material-row, .pane-actions .el-button, .footer-tabs')];
    return { overflow: document.documentElement.scrollWidth > innerWidth, list: rect(list), detail: rect(detail),
      rows: [...document.querySelectorAll('.part-row')].map(el => ({ label:el.textContent.trim(), title:el.title, ...rect(el), scrollWidth:el.scrollWidth, clientWidth:el.clientWidth })),
      overflowing: elements.filter(el => el.scrollWidth > el.clientWidth + 1).map(el => el.className),
      materialLabels: [...document.querySelectorAll('.material-name')].map(el => ({ ...rect(el), scrollWidth:el.scrollWidth, clientWidth:el.clientWidth })),
      fontSize:parseFloat(getComputedStyle(document.querySelector('.avm')).fontSize),
      header:[...document.querySelector('.avm-header').children].map(rect),
    };
  })()`);
  check(!metrics.overflow, `${name}: page must not overflow horizontally`);
  check(metrics.list.width >= metrics.fontSize * 6, `${name}: parts lane must scale with readable text, got ${metrics.list.width}px`);
  check(metrics.list.right <= metrics.detail.x, `${name}: parts lane overlaps materials`);
  check(metrics.rows.every(row => row.scrollWidth <= row.clientWidth + 1), `${name}: part label escapes its button`);
  check(metrics.rows.every(row => !row.label.includes('ch03_037_')), `${name}: equipment IDs must not repeat in the parts lane`);
  check(metrics.rows.every(row => row.title.includes('ch03_037_')), `${name}: full part IDs must remain available`);
  check(!metrics.overflowing.length, `${name}: content overflows ${metrics.overflowing.join(', ')}`);
  check(metrics.materialLabels.every(label => label.right <= metrics.detail.right + 1), `${name}: long material labels escape detail`);
  check(metrics.header.every((item, index) => metrics.header.slice(index + 1).every(other => item.right <= other.x || other.right <= item.x || item.y + item.height <= other.y || other.y + other.height <= item.y)), `${name}: header identity overlaps controls`);
  const result = await cdp('Page.captureScreenshot', { format: 'png', captureBeyondViewport: true, fromSurface: true });
  await writeFile(new URL(`../test-results/${name}.png`, import.meta.url), Buffer.from(result.data, 'base64'));
  await evaluate(`document.querySelector('#fixture-controls').style.display = 'flex'`);
  return metrics;
}
async function contrast(selector) {
  return evaluate(`(() => {
    const el = document.querySelector(${JSON.stringify(selector)}), style = getComputedStyle(el);
    const luminance = color => { const values = color.match(/[\\d.]+/g).slice(0,3).map(Number).map(v => {v /= 255; return v <= .04045 ? v/12.92 : ((v+.055)/1.055)**2.4;}); return values[0]*.2126+values[1]*.7152+values[2]*.0722; };
    const ink = luminance(style.color), bg = luminance(style.backgroundColor);
    return { ratio:(Math.max(ink,bg)+.05)/(Math.min(ink,bg)+.05), opacity:Number(style.opacity), color:style.color, background:style.backgroundColor };
  })()`);
}
async function primaryStates() {
  const selector = '.presets-pane .el-button--primary';
  const normal = await contrast(selector);
  check(normal.ratio >= 4.5, `Enabled primary contrast: ${JSON.stringify(normal)}`);
  await evaluate(`document.querySelector('${selector}').scrollIntoView({ block:'center' })`);
  const center = await evaluate(`(() => { const r = document.querySelector('${selector}').getBoundingClientRect(); return { x:r.x+r.width/2, y:r.y+r.height/2 }; })()`);
  await cdp('Input.dispatchMouseEvent', { type: 'mouseMoved', ...center });
  check(await evaluate(`document.querySelector('${selector}').matches(':hover')`), 'Primary hover state must be exercised');
  check((await contrast(selector)).ratio >= 4.5, 'Hovered primary must remain readable');
  await cdp('Input.dispatchMouseEvent', { type: 'mousePressed', ...center, button: 'left', clickCount: 1 });
  check(await evaluate(`document.querySelector('${selector}').matches(':active')`), 'Primary pressed state must be exercised');
  check((await contrast(selector)).ratio >= 4.5, 'Pressed primary must remain readable');
  await cdp('Input.dispatchMouseEvent', { type: 'mouseMoved', x: 1, y: 1, button: 'left', buttons: 1 });
  await cdp('Input.dispatchMouseEvent', { type: 'mouseReleased', x: 1, y: 1, button: 'left' });
  await evaluate(`document.getElementById('preset-name').focus()`);
  await cdp('Input.dispatchKeyEvent', { type: 'keyDown', key: 'Tab', code: 'Tab', windowsVirtualKeyCode: 9 });
  await cdp('Input.dispatchKeyEvent', { type: 'keyUp', key: 'Tab', code: 'Tab', windowsVirtualKeyCode: 9 });
  check(await evaluate(`document.activeElement.matches('${selector}') && getComputedStyle(document.activeElement).outlineStyle !== 'none'`), 'Keyboard focus on the primary must be visible');
}
try {
  await cdp('Runtime.enable'); await cdp('Page.enable');
  await mkdir(new URL('../test-results/', import.meta.url), { recursive: true });
  await until(`document.querySelector('.footer-tabs') && !document.querySelector('.connection-state')`);
  await measure('layout-empty-1654', 1654, 1091);
  check(await evaluate(`document.querySelector('.material-list .empty-note').textContent.includes('当前分组')`), 'Empty state must describe the current group, not assert engine materials are missing');
  const disabled = await contrast('.presets-pane .el-button--primary');
  check(disabled.ratio >= 4.5 && disabled.opacity === 1, `Disabled primary must remain readable: ${JSON.stringify(disabled)}`);
  check((await contrast('.groups-pane .pane-actions > .el-button.is-disabled')).ratio >= 4.5, 'Disabled secondary must remain readable');
  await click('.part-row:nth-child(2)');
  await measure('layout-materials-1158', 1158, 684);
  await click('.presets-pane .catalog-row');
  await primaryStates();
  await click('#fixture-controls button', 'REFF violet / 140%');
  await until(`parseFloat(getComputedStyle(document.querySelector('.avm')).fontSize) > 19`);
  await measure('layout-chinese-140-1654', 1654, 1091);
  await click('#fixture-controls button', 'REFF amber');
  await until(`parseFloat(getComputedStyle(document.querySelector('.avm')).fontSize) === 14`);
  await click('#fixture-controls button', 'Long English labels');
  await until(`document.querySelector('.identity h1').textContent === 'Armor Variant Manager'`);
  await measure('layout-english-1158', 1158, 684);
  await click('#fixture-controls button', 'REFF violet / 140%');
  await until(`parseFloat(getComputedStyle(document.querySelector('.avm')).fontSize) > 19`);
  await measure('layout-140-1654', 1654, 1091);
  await measure('layout-140-1158', 1158, 684);
  await measure('layout-140-narrow', 700, 900);
  await measure('layout-140-small', 400, 850);
  const ownAccent = await evaluate(`getComputedStyle(document.querySelector('.avm')).getPropertyValue('--avm-accent').trim()`);
  check(ownAccent === '#76d8dc', 'Own theme must retain ice cyan while REFF text scale changes');
  await click('.footer-tabs button', 'Settings');
  await click('.theme-settings .el-radio', 'Follow REFF');
  await click('.footer-tabs button', 'Parts & materials');
  const followed = await evaluate(`({ avm:getComputedStyle(document.querySelector('.avm')).getPropertyValue('--avm-accent').trim(), shared:getComputedStyle(document.documentElement).getPropertyValue('--reff-accent').trim() })`);
  check(followed.avm === followed.shared && followed.avm === '#c8a0ef', 'Follow REFF must use the live shared accent');
  await measure('layout-reff-140-narrow', 700, 900);
  await primaryStates();
  await evaluate(`(() => { const input = document.getElementById('preset-name'); Object.getOwnPropertyDescriptor(HTMLInputElement.prototype, 'value').set.call(input, ''); input.dispatchEvent(new Event('input', { bubbles:true })); })()`);
  await until(`document.querySelector('.presets-pane .el-button--primary').disabled`);
  check((await contrast('.presets-pane .el-button--primary')).ratio >= 4.5, 'Disabled primary must remain readable while following REFF');
  check(errors.length === 0, `Browser errors: ${errors.join('; ')}`);
  assert.deepEqual(failures, []);
  console.log('Layout fixture passed: bounded part labels with full IDs; group-scoped empty state; readable primary states; long bilingual materials; 1654/1158/700/400 layouts at 140%; ice-cyan and live REFF themes.');
} finally {
  await new Promise(resolve => { socket.onclose = resolve; socket.close(); });
  await fetch(`${endpoint}/json/close/${tab.id}`);
}
