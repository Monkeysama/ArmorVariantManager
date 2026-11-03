import assert from 'node:assert/strict';
import { mkdir, writeFile } from 'node:fs/promises';

// Use a separate headless browser with its own profile, never a user's session.
const endpoint = process.argv[2];
if (!endpoint) throw new Error('Usage: node web/tests/import-browser.mjs <CDP endpoint> [fixture URL]');
const fixture = process.argv[3] ?? 'http://127.0.0.1:5178/tests/fixture.html?controls';
const tab = await (await fetch(`${endpoint}/json/new?${fixture}`, { method: 'PUT' })).json();
const socket = new WebSocket(tab.webSocketDebuggerUrl);
await new Promise((resolve, reject) => { socket.onopen = resolve; socket.onerror = reject; });
let sequence = 0;
const pending = new Map(), errors = [];
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
async function settled() { await pause(180); await until(`document.querySelector('.avm')?.getAttribute('aria-busy') === 'false'`); }
async function click(selector, text) {
  await evaluate(`(() => { const el = [...document.querySelectorAll(${JSON.stringify(selector)})].find(el => el.getClientRects().length && ${text === undefined ? 'true' : `el.textContent.trim() === ${JSON.stringify(text)}`}); if (!el || el.disabled) throw new Error('Clickable control not found: ' + ${JSON.stringify(text ?? selector)}); el.click(); })()`);
  await settled();
}
async function calls() { return evaluate(`JSON.parse(document.querySelector('#fixture-controls output').textContent).calls`); }
async function lastCall() { const list = await calls(); return list[list.length - 1]; }
async function status() { return evaluate(`JSON.parse(document.querySelector('#fixture-controls output').textContent)`); }
async function helpReady() { await until(`document.querySelector('.help-content') && document.querySelector('.help-page').getAttribute('aria-busy') === 'false'`); }

async function importsReady() { await until(`document.querySelector('.import-picker')?.getAttribute('aria-busy') === 'false'`); }
async function choose(index) { await click(`.import-file:nth-child(${index}) input`); }
async function pickerScreenshot(name, narrow = false) {
  await evaluate(`document.activeElement?.blur(); document.querySelector('#fixture-controls').style.display = 'none'; window.scrollTo(0, ${narrow ? `Math.max(0, document.querySelector('.import-picker').getBoundingClientRect().top + scrollY - 16)` : '0'})`);
  await pause(250);
  const metrics = await cdp('Page.getLayoutMetrics');
  const clip = narrow ? undefined : { x: 0, y: 0, width: metrics.cssContentSize.width, height: metrics.cssContentSize.height, scale: 1 };
  const result = await cdp('Page.captureScreenshot', { format: 'png', captureBeyondViewport: !narrow, fromSurface: true, clip });
  await writeFile(new URL(`../test-results/${name}.png`, import.meta.url), Buffer.from(result.data, 'base64'));
  await evaluate(`document.querySelector('#fixture-controls').style.display = 'flex'`);
}

try {
  await cdp('Runtime.enable');
  await cdp('Emulation.setDeviceMetricsOverride', { width: 1280, height: 850, deviceScaleFactor: 1, mobile: false });
  await mkdir(new URL('../test-results/', import.meta.url), { recursive: true });
  await until(`document.querySelector('.footer-tabs') && !document.querySelector('.connection-state')`);
  assert.equal(await evaluate(`!!document.querySelector('.import-trigger')`), false);
  assert.equal((await status()).imports.length, 0);
  await click('#fixture-controls button', 'English / Rise');
  await until(`!!document.querySelector('.import-trigger')`);
  assert.equal(await evaluate(`document.querySelectorAll('.presets-pane .catalog-row').length`), 3);
  await pause(1200);
  assert.equal((await status()).imports.length, 0, 'polling never downloads import options');

  await click('#fixture-controls button', 'No character');
  await until(`document.querySelector('.equipment-id').textContent === '—'`);
  assert.equal(await evaluate(`document.querySelector('.import-trigger').disabled`), true);
  await click('#fixture-controls button', 'Restore character');
  await until(`!document.querySelector('.import-trigger').disabled`);
  let count = (await calls()).length;
  await click('.import-trigger'); await importsReady();
  assert.equal((await status()).imports.length, 1);
  assert.equal(await evaluate(`document.querySelectorAll('.import-file').length`), 2, 'armor options exclude weapons');
  assert.match(await evaluate(`document.querySelector('.import-warning').textContent`), /replace the entire current equipment configuration/);
  assert.match(await evaluate(`document.querySelector('.import-files').textContent`), /\[backup\]/);
  assert.equal(await evaluate(`document.querySelector('.import-actions .el-button--primary').disabled`), true);
  await choose(2);
  await evaluate(`document.querySelector('.import-file:nth-child(2) input').focus()`);
  await cdp('Input.dispatchKeyEvent', { type: 'keyDown', key: 'Enter', code: 'Enter', windowsVirtualKeyCode: 13 });
  await cdp('Input.dispatchKeyEvent', { type: 'keyUp', key: 'Enter', code: 'Enter', windowsVirtualKeyCode: 13 });
  assert.equal((await calls()).length, count, 'choosing a file cannot submit the existing preset-save form');
  await click('.import-actions button', 'Cancel');
  assert.equal((await calls()).length, count);
  assert.equal(await evaluate(`!!document.querySelector('.import-picker')`), false);

  // A failed save retains the selected source and its exact path for retry.
  await click('.import-trigger'); await importsReady();
  assert.equal((await status()).imports.length, 2);
  await choose(2);
  await click('#fixture-controls button', 'Fail next action');
  await click('.import-actions button', 'Confirm import');
  assert.match(await evaluate(`document.querySelector('.error-banner').textContent`), /保存失败/);
  assert.equal(await evaluate(`document.querySelector('.import-file:nth-child(2) input').checked`), true);
  assert.equal(await evaluate(`document.querySelector('.import-actions .el-button--primary').disabled`), false);
  await pickerScreenshot('import-rise-save-error');
  const expected = { kind: 'import-preset', path: 'ArmorVariantManager/pl001_0000.json.backup', bodyId: 'ch03_001_0000' };
  assert.deepEqual(await lastCall(), expected);
  await click('.import-actions button', 'Confirm import');
  assert.deepEqual(await lastCall(), expected);
  assert.equal(await evaluate(`!!document.querySelector('.import-picker')`), false);
  assert.equal(await evaluate(`document.querySelector('.presets-pane .catalog-row').textContent.includes('Imported preset')`), true);
  assert.equal(await evaluate(`document.querySelector('.presets-pane .active-dot') !== null`), true);

  // List errors retry in place; an empty Lua table is a valid empty list.
  await click('#fixture-controls button', 'Fail next imports');
  await click('.import-trigger'); await importsReady();
  assert.match(await evaluate(`document.querySelector('.import-error').textContent`), /无法读取配置目录/);
  await click('.import-refresh'); await importsReady();
  assert.equal(await evaluate(`!!document.querySelector('.import-error')`), false);
  assert.equal(await evaluate(`document.querySelectorAll('.import-file').length`), 2);
  await choose(1);
  await click('#fixture-controls button', 'Empty import list');
  await click('.import-refresh'); await importsReady();
  assert.equal(await evaluate(`document.querySelectorAll('.import-file').length`), 0);
  assert.match(await evaluate(`document.querySelector('.import-status').textContent`), /No equipment JSON files or backups found/);
  assert.equal(await evaluate(`document.querySelector('.import-actions .el-button--primary').disabled`), true);
  await click('#fixture-controls button', 'Empty import list');
  await click('.import-refresh'); await importsReady();
  assert.equal(await evaluate(`document.querySelectorAll('.import-file').length`), 2);
  await choose(1);
  await pickerScreenshot('import-rise-english');

  // Switching equipment or armor/weapon mode closes stale choices.
  await click('#fixture-controls button', 'Other equipment');
  await until(`document.querySelector('.equipment-id').textContent === 'ch03_002_0000'`);
  assert.equal(await evaluate(`!!document.querySelector('.import-picker')`), false);
  await click('.import-trigger'); await importsReady();
  await choose(1);
  await click('.mode-switch button', 'Weapon');
  assert.equal(await evaluate(`!!document.querySelector('.import-picker')`), false);
  await click('.import-trigger'); await importsReady();
  assert.equal(await evaluate(`document.querySelectorAll('.import-file').length`), 3, 'weapon mode includes all source files');
  await click('.import-actions button', 'Cancel');

  // Slow list reads, queued writes, documentation and polls use the same lane.
  await click('#fixture-controls button', 'Slow next imports');
  const importCount = (await status()).imports.length;
  await click('.import-trigger');
  await until(`document.querySelector('.import-picker').getAttribute('aria-busy') === 'true'`);
  await click('.footer-tabs button', 'Help');
  await evaluate(`document.querySelector('.mode-switch button:first-child').click()`);
  await settled(); await helpReady();
  assert.equal((await status()).imports.length, importCount + 1);
  assert.equal((await status()).peak, 1);
  await click('.footer-tabs button', 'Parts & materials');
  assert.equal(await evaluate(`!!document.querySelector('.import-picker')`), false);

  // The picker inherits the existing REFF palette and 140% font in a narrow window.
  await click('.footer-tabs button', 'Settings');
  await click('.theme-settings .el-radio', 'Follow REFF');
  await click('#fixture-controls button', 'REFF violet / 140%');
  await click('#fixture-controls button', 'Chinese only');
  await until(`document.querySelector('.footer-tabs button:last-child').textContent === '帮助'`);
  await click('.footer-tabs button', '部件材质');
  await cdp('Emulation.setDeviceMetricsOverride', { width: 420, height: 850, deviceScaleFactor: 1, mobile: false });
  await click('.import-trigger'); await importsReady();
  await choose(2);
  await pickerScreenshot('import-reff-narrow-140', true);
  assert.equal(await evaluate(`document.documentElement.scrollWidth > innerWidth`), false);
  assert.equal(await evaluate(`document.querySelector('.import-file-list').scrollWidth > document.querySelector('.import-file-list').clientWidth`), false);
  assert.equal(await evaluate(`document.querySelector('.avm').dataset.theme`), 'reff');
  assert.equal(await evaluate(`getComputedStyle(document.querySelector('.import-warning')).fontSize`), '19.6px');
  await click('.import-actions button', '取消');
  await click('#fixture-controls button', 'Chinese / Wilds');
  await until(`document.querySelector('.game-identity').textContent.includes('荒野')`);
  assert.equal(await evaluate(`!!document.querySelector('.import-trigger')`), false);
  assert.equal((await status()).peak, 1);
  assert.deepEqual(errors, []);
  console.log('Manual import browser fixture passed: Rise-only capability, existing presets and no-character state; choose/cancel/confirm, guarded backup path, failed save retention/retry, list retry/empty Lua table, equipment/mode invalidation, armor/weapon sources, serialized on-demand reads/writes/help and REFF 420 px / 140%.');
} finally {
  socket.close();
  await fetch(`${endpoint}/json/close/${tab.id}`);
}
