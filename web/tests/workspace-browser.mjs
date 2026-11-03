import assert from 'node:assert/strict';
import { mkdir, writeFile } from 'node:fs/promises';

// Use a separately launched headless Chrome profile, never the user's session.
const endpoint = process.argv[2];
if (!endpoint) throw new Error('Usage: node web/tests/workspace-browser.mjs <CDP endpoint>');
const url = 'http://127.0.0.1:5178/tests/fixture.html?controls&workspace';
const tab = await (await fetch(`${endpoint}/json/new?${encodeURIComponent(url)}`, { method: 'PUT' })).json();
const socket = new WebSocket(tab.webSocketDebuggerUrl);
await new Promise((resolve, reject) => { socket.onopen = resolve; socket.onerror = reject; });
let sequence = 0;
const pending = new Map(), errors = [];
socket.onmessage = event => {
  const message = JSON.parse(event.data);
  if (message.method === 'Runtime.exceptionThrown') errors.push(message.params.exceptionDetails.text);
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
  await evaluate(`(() => { const el = [...document.querySelectorAll(${JSON.stringify(selector)})].find(el => ${selector.startsWith('#fixture-controls') ? 'true' : 'el.getClientRects().length'} && ${text === undefined ? 'true' : `el.textContent.trim() === ${JSON.stringify(text)}`}); if (!el || el.disabled) throw new Error('Clickable control not found: ' + ${JSON.stringify(text ?? selector)}); el.click(); })()`);
  await pause(160); await until(`document.querySelector('.avm')?.getAttribute('aria-busy') === 'false'`);
}
async function input(id, value) {
  await evaluate(`(() => { const el = document.getElementById(${JSON.stringify(id)}); el.value = ${JSON.stringify(String(value))}; el.dispatchEvent(new Event('input', { bubbles: true })); })()`);
  await pause(50);
}
const calls = () => evaluate(`JSON.parse(document.querySelector('#fixture-controls output').textContent).calls`);
async function screenshot(name) {
  await evaluate(`document.getElementById('fixture-controls').style.display = 'none'`);
  await pause(100);
  const result = await cdp('Page.captureScreenshot', { format: 'png' });
  await writeFile(new URL(`../test-results/${name}.png`, import.meta.url), Buffer.from(result.data, 'base64'));
}
async function frame(width, height) {
  await cdp('Emulation.setDeviceMetricsOverride', { width, height, deviceScaleFactor: 1, mobile: false });
  await pause(120);
}
async function fixedChrome() {
  const before = await evaluate(`(() => { const rect = s => { const r = document.querySelector(s).getBoundingClientRect(); return [r.top,r.bottom]; }; return [rect('.avm-header'),rect('.avm-footer')]; })()`);
  await evaluate(`document.querySelector('.avm-content').scrollTop = 100000; window.scrollTo(0,100000)`);
  await pause(80);
  const after = await evaluate(`(() => { const rect = s => { const r = document.querySelector(s).getBoundingClientRect(); return [r.top,r.bottom]; }; return { chrome:[rect('.avm-header'),rect('.avm-footer')], doc:document.documentElement.scrollHeight, height:innerHeight, width:innerWidth, scrollWidth:document.documentElement.scrollWidth }; })()`);
  assert.deepEqual(after.chrome, before, 'Header and footer must not participate in middle-content scrolling');
  assert(after.doc <= after.height + 1 && after.scrollWidth <= after.width + 1, 'Only the middle workspace may scroll');
  assert(before[0][0] === 0 && before[1][1] <= after.height + 1, 'Both fixed bars must remain inside the iframe');
}
try {
  await cdp('Runtime.enable'); await cdp('Page.enable');
  await mkdir(new URL('../test-results/', import.meta.url), { recursive: true });
  await until(`document.querySelector('.footer-tabs') && !document.querySelector('.connection-state')`);
  await frame(1158, 684);
  await evaluate(`document.getElementById('fixture-controls').style.display = 'none'`);
  const defects = await evaluate(`(() => {
    const layouts = JSON.parse(document.querySelector('#fixture-controls output').textContent).layouts;
    return [!layouts.some(item => item.padding === 0) && 'Plugin padding was not set to zero',
      !document.querySelector('.avm-content') && 'No bounded middle scroll region',
      !document.querySelector('.materials-pane [data-setting="ground_clipping_height_cm"]') && 'Height controls are not below parts and materials',
      ![...document.querySelectorAll('.groups-pane button')].some(el => el.textContent.trim() === '新增分组') && 'New group entry is missing'].filter(Boolean);
  })()`);
  assert.deepEqual(defects, [], 'Four reported workspace defects');
  await fixedChrome();
  await click('.part-row:nth-child(2)');
  const heightBounds = await evaluate(`(() => { const pane = document.querySelector('.materials-pane').getBoundingClientRect(), height = document.querySelector('.height-pane').getBoundingClientRect(), materials = document.querySelector('.materials-layout').getBoundingClientRect(); return { pane:[pane.left,pane.right], height:[height.left,height.right], after:height.top >= materials.bottom }; })()`);
  assert(heightBounds.after && Math.abs(heightBounds.pane[0] - heightBounds.height[0]) < 15 && Math.abs(heightBounds.pane[1] - heightBounds.height[1]) < 15, 'Height must span the original full right pane below both columns');
  await click('.groups-pane .new-group-button');
  assert.deepEqual((await calls()).at(-1), { kind: 'selection', enabled: true, bodyId: 'ch03_001_0000' });
  await input('group-name', '披风');
  await click('.material-row:nth-child(3) .el-checkbox');
  await click('#fixture-controls button', 'Fail next action');
  await click('.groups-pane .create-group-button');
  assert.equal(await evaluate(`document.getElementById('group-name').value`), '披风', 'Failed save must retain group name');
  assert.equal(await evaluate(`document.querySelector('.selection-hint') !== null`), true, 'Failed creation must preserve pending material selection');
  await click('.groups-pane .create-group-button');
  await until(`[...document.querySelectorAll('.groups-pane .row-name')].some(el => el.textContent === '披风')`);
  assert.equal((await calls()).at(-1).global, false);
  assert.equal(await evaluate(`!!document.getElementById('group-name')`), false);
  await click('.groups-pane .new-group-button');
  await click('.material-row:nth-child(3) .el-checkbox');
  await click('.groups-pane .cancel-group-button');
  assert.equal((await calls()).at(-1).enabled, false);
  assert.equal(await evaluate(`!!document.querySelector('.selection-hint')`), false);
  await click('.groups-pane .new-group-button');
  await input('group-name', '全局披风');
  await click('.groups-pane .global-group-toggle');
  await click('.material-row:nth-child(3) .el-checkbox');
  await screenshot('workspace-create-group');
  await click('.groups-pane .create-group-button');
  assert.equal((await calls()).at(-1).global, true);
  await input('setting-ground_clipping_height_cm', 12.5);
  await evaluate(`document.getElementById('setting-ground_clipping_height_cm').dispatchEvent(new KeyboardEvent('keyup', { key:'Enter', bubbles:true }))`);
  await until(`document.querySelector('.avm').getAttribute('aria-busy') === 'false'`);
  assert.equal((await calls()).at(-1).value, 12.5);
  await click('[data-setting="ground_clipping_reset"] button');
  assert.deepEqual((await calls()).at(-1), { kind: 'setting', id: 'ground_clipping_reset', bodyId: 'ch03_001_0000' });
  assert.equal(await evaluate(`document.getElementById('setting-ground_clipping_height_cm').value`), '0');
  await screenshot('workspace-wilds-fixed');
  await click('.footer-tabs button', '设置');
  assert.equal(await evaluate(`!!document.querySelector('.settings-page [data-setting="ground_clipping_height_cm"]')`), false, 'Height must not be duplicated in settings');
  await fixedChrome();
  await click('.footer-tabs button', '帮助');
  await until(`document.querySelector('.help-content h2')`);
  await fixedChrome();
  await click('.footer-tabs button', '部件材质');
  await click('.mode-switch button', '武器');
  assert.equal(await evaluate(`document.querySelector('.height-pane') === null`), true);
  await click('.mode-switch button', '防具');
  await click('#fixture-controls button', 'English / Rise');
  await until(`document.querySelector('.identity h1').textContent === 'Armor Variant Manager'`);
  assert.equal(await evaluate(`document.querySelector('.height-pane') === null`), true);
  await click('.groups-pane .new-group-button');
  await input('group-name', 'Empty Rise group');
  await click('.groups-pane .create-group-button');
  assert.equal((await calls()).at(-1).name, 'Empty Rise group', 'Rise must retain its legacy empty-group contract');
  await click('#fixture-controls button', 'REFF violet / 140%');
  await until(`parseFloat(getComputedStyle(document.querySelector('.avm')).fontSize) > 19`);
  await frame(700, 900); await fixedChrome(); await screenshot('workspace-rise-140-narrow');
  await frame(400, 850); await fixedChrome(); await screenshot('workspace-rise-140-small');
  await click('#fixture-controls button', 'No character');
  await until(`document.querySelector('.equipment-id').textContent === '—'`);
  assert.equal(await evaluate(`document.querySelector('.new-group-button').disabled`), true);
  assert.equal((await evaluate(`JSON.parse(document.querySelector('#fixture-controls output').textContent).peak`)), 1);
  assert.deepEqual(errors, []);
  console.log('PASS: padding zero, fixed chrome, original height location/reset, group create/cancel/failure/global and Rise contracts');
} finally {
  await cdp('Page.close').catch(() => {}); socket.close();
}
