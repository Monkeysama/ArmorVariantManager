import assert from 'node:assert/strict';
import { mkdir, writeFile } from 'node:fs/promises';

// Use a separate headless browser with its own profile, never a user's session.
const endpoint = process.argv[2];
if (!endpoint) throw new Error('Usage: node web/tests/help-backup-browser.mjs <CDP endpoint> [fixture URL]');
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
async function screenshot(name) {
  await evaluate(`document.activeElement?.blur(); window.scrollTo(0,0)`);
  await cdp('Input.dispatchMouseEvent', { type: 'mousePressed', x: 1, y: 1, button: 'left', clickCount: 1 });
  await cdp('Input.dispatchMouseEvent', { type: 'mouseReleased', x: 1, y: 1, button: 'left', clickCount: 1 });
  await evaluate(`document.querySelector('#fixture-controls').style.display = 'none'`);
  await pause(250);
  const result = await cdp('Page.captureScreenshot', { format: 'png', captureBeyondViewport: true, fromSurface: true });
  await writeFile(new URL(`../test-results/${name}.png`, import.meta.url), Buffer.from(result.data, 'base64'));
  await evaluate(`document.querySelector('#fixture-controls').style.display = 'flex'`);
}
async function status() { return evaluate(`JSON.parse(document.querySelector('#fixture-controls output').textContent)`); }
async function helpReady() { await until(`document.querySelector('.help-content') && document.querySelector('.help-page').getAttribute('aria-busy') === 'false'`); }

try {
  await cdp('Runtime.enable');
  await cdp('Emulation.setDeviceMetricsOverride', { width: 1280, height: 850, deviceScaleFactor: 1, mobile: false });
  await mkdir(new URL('../test-results/', import.meta.url), { recursive: true });
  await until(`document.querySelector('.footer-tabs') && !document.querySelector('.connection-state')`);
  assert.equal((await status()).documents.length, 0);
  assert.equal(await evaluate(`!!document.querySelector('.backup-warning')`), false);
  assert.equal(await evaluate(`!!document.querySelector('.restore-button, .restore-confirm')`), false);

  await click('#fixture-controls button', 'Backup pending');
  await until(`!!document.querySelector('.backup-warning')`);
  let count = (await calls()).length;
  await click('.backup-warning button', '恢复备份');
  assert.equal((await calls()).length, count);
  assert.match(await evaluate(`document.querySelector('.backup-warning .restore-confirm').textContent`), /覆盖当前装备配置/);
  await screenshot('backup-confirm-ice-cyan');
  await click('.backup-warning button', '取消');
  assert.equal((await calls()).length, count);
  assert.equal(await evaluate(`!!document.querySelector('.backup-warning .restore-confirm')`), false);

  // Failed dismiss and failed restore both retain the warning and permit retry.
  await click('#fixture-controls button', 'Fail next action');
  await click('.backup-warning button', '忽略');
  assert.match(await evaluate(`document.querySelector('.error-banner').textContent`), /保存失败/);
  assert.equal(await evaluate(`!!document.querySelector('.backup-warning')`), true);
  await click('.backup-warning button', '忽略');
  assert.deepEqual(await lastCall(), { kind: 'dismiss-backup', bodyId: 'ch03_001_0000' });
  assert.equal(await evaluate(`!!document.querySelector('.backup-warning')`), false);
  assert.equal(await evaluate(`!!document.querySelector('.restore-button, .restore-confirm')`), false);
  await click('#fixture-controls button', 'Backup pending');
  await until(`!!document.querySelector('.backup-warning')`);
  await click('.backup-warning button', '恢复备份');
  await click('#fixture-controls button', 'Fail next action');
  await click('.backup-warning button', '恢复备份');
  assert.equal(await evaluate(`!!document.querySelector('.backup-warning .restore-confirm')`), true);
  await click('.backup-warning button', '恢复备份');
  assert.deepEqual(await lastCall(), { kind: 'restore', bodyId: 'ch03_001_0000' });
  assert.equal(await evaluate(`!!document.querySelector('.backup-warning')`), false);
  assert.equal(await evaluate(`!!document.querySelector('.restore-button, .restore-confirm')`), false);

  await click('#fixture-controls button', 'Backup pending');
  await until(`!!document.querySelector('.backup-warning')`);
  await click('.backup-warning button', '恢复备份');
  await click('#fixture-controls button', 'Other equipment');
  await until(`document.querySelector('.equipment-id').textContent === 'ch03_002_0000'`);
  assert.equal(await evaluate(`!!document.querySelector('.restore-confirm')`), false);
  await click('#fixture-controls button', 'No character');
  await until(`document.querySelector('.equipment-id').textContent === '—'`);
  assert.equal(await evaluate(`!!document.querySelector('.backup-warning')`), false);
  assert.equal(await evaluate(`!!document.querySelector('.restore-button, .restore-confirm')`), false);
  assert.equal(await evaluate(`document.querySelector('.equipment-loading').getAttribute('role')`), 'status');
  assert.match(await evaluate(`document.querySelector('.equipment-loading').textContent`), /防具/);

  // Help is independent of character state. Error recovery is local to this panel.
  await click('#fixture-controls button', 'Fail next help');
  await click('.footer-tabs button', '帮助');
  await until(`!!document.querySelector('.help-error')`);
  assert.match(await evaluate(`document.querySelector('.help-error').textContent`), /帮助读取失败/);
  await screenshot('help-error');
  await click('.help-error button', '重新读取');
  await helpReady();
  assert.deepEqual(await evaluate(`Array.from(document.querySelectorAll('.help-tabs button'), el => el.id)`), ['help-tab-configure', 'help-tab-usage', 'help-tab-changelog']);
  assert.equal(await evaluate(`document.querySelectorAll('.help-content .help-entry').length`), 8);
  await screenshot('help-wilds-chinese');
  count = (await status()).documents.length;
  await click('.footer-tabs button', '部件材质');
  await click('.footer-tabs button', '帮助');
  await helpReady(); await pause(1300);
  assert.equal((await status()).documents.length, count);
  await click('#help-tab-changelog');
  assert.equal(await evaluate(`document.querySelectorAll('.help-content .help-entry').length`), 22);
  assert.equal(await evaluate(`document.querySelector('.help-content').scrollHeight > document.querySelector('.help-content').clientHeight`), true);
  await evaluate(`document.querySelector('.help-content').scrollTop = document.querySelector('.help-content').scrollHeight`);
  assert.equal(await evaluate(`document.querySelector('.help-content').scrollTop > 0`), true);
  await screenshot('help-changelog-bottom');
  await evaluate(`document.getElementById('help-tab-changelog').dispatchEvent(new KeyboardEvent('keydown', { key: 'Home', bubbles: true }))`);
  await until(`document.activeElement?.id === 'help-tab-configure'`);
  assert.equal(await evaluate(`document.querySelector('.help-content').scrollTop`), 0);

  // A slow documentation response and a subsequent write cannot overlap.
  await click('#fixture-controls button', 'Slow next help');
  await click('#fixture-controls button', 'English only');
  await until(`document.querySelector('.help-page').getAttribute('aria-busy') === 'true'`);
  await evaluate(`document.querySelector('.mode-switch button:last-child').click()`);
  await until(`document.querySelector('.avm').getAttribute('aria-busy') === 'true'`);
  await settled(); await helpReady();
  assert.equal(await evaluate(`document.querySelector('.equipment-id').textContent`), 'wp00_000_0000');
  assert.equal(await evaluate(`document.querySelector('.help-tabs button').textContent`), 'How to Configure');
  assert.equal((await status()).peak, 1);
  await screenshot('help-wilds-english');
  await click('#fixture-controls button', 'No character');
  await until(`document.querySelector('.equipment-id').textContent === '—'`);
  assert.equal(await evaluate(`!!document.querySelector('.backup-warning, .restore-button, .restore-confirm')`), false);
  assert.equal(await evaluate(`document.querySelector('.equipment-loading').getAttribute('role')`), 'status');
  assert.match(await evaluate(`document.querySelector('.equipment-loading').textContent`), /weapon/i);
  await click('#fixture-controls button', 'Restore character');
  await until(`!document.querySelector('.equipment-loading')`);
  count = (await status()).documents.length;
  await click('#fixture-controls button', 'Rise only');
  await until(`document.querySelector('.game-identity').textContent.includes('RISE')`);
  await helpReady();
  assert.equal((await status()).documents.length, count + 1);
  assert.equal(await evaluate(`document.querySelectorAll('.help-content .help-entry').length`), 7);
  assert.doesNotMatch(await evaluate(`document.querySelector('.help-content').textContent`), /visual height in Wilds/);
  await click('#help-tab-usage');
  await screenshot('help-rise-english');
  count = (await status()).documents.length;
  await click('#fixture-controls button', 'Chinese only');
  await until(`document.querySelector('.footer-tabs button:last-child').textContent === '帮助'`);
  await helpReady();
  assert.equal((await status()).documents.length, count + 1);
  await click('#help-tab-configure');
  assert.equal(await evaluate(`document.querySelectorAll('.help-content .help-entry').length`), 7);
  assert.doesNotMatch(await evaluate(`document.querySelector('.help-content').textContent`), /荒野高跟鞋/);
  await screenshot('help-rise-chinese');

  // Shared theme and 140% typography remain readable in a narrow panel.
  await click('.footer-tabs button', '设置');
  await click('.theme-settings .el-radio', '跟随 REFF');
  await click('#fixture-controls button', 'REFF violet / 140%');
  await click('.footer-tabs button', '帮助');
  await cdp('Emulation.setDeviceMetricsOverride', { width: 420, height: 850, deviceScaleFactor: 1, mobile: false });
  await screenshot('help-reff-narrow-140');
  assert.equal(await evaluate(`document.documentElement.scrollWidth > innerWidth`), false);
  assert.equal(await evaluate(`document.querySelector('.help-content').scrollWidth > document.querySelector('.help-content').clientWidth`), false);
  assert.equal(await evaluate(`document.querySelector('.avm').dataset.theme`), 'reff');
  assert.equal(await evaluate(`getComputedStyle(document.querySelector('.help-content p')).fontSize`), '19.6px');
  assert.equal(await evaluate(`(() => { const button = document.querySelector('.backup-actions button'); return button.clientHeight < parseFloat(getComputedStyle(button).lineHeight) * 2 + 12; })()`), true);
  assert.equal((await status()).peak, 1);
  assert.deepEqual(errors, []);
  console.log('Backup/help browser fixture passed: guarded ignore and restore, first-click/cancel, failed writes, equipment change and no-character state; complete bilingual docs, per-game filtering, lazy cache, retry, serial slow-read/write, keyboard tabs, long-text scrolling and REFF theme at 420 px / 140%.');
} finally {
  socket.close();
  await fetch(`${endpoint}/json/close/${tab.id}`);
}
