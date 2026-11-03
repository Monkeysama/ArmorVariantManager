import assert from 'node:assert/strict';
import { mkdir, writeFile } from 'node:fs/promises';

// Run against a separate headless browser's CDP endpoint, never a user's session.
const endpoint = process.argv[2];
if (!endpoint) throw new Error('Usage: node web/tests/conditions-browser.mjs <CDP endpoint> [fixture URL]');
const fixture = process.argv[3] ?? 'http://127.0.0.1:5178/tests/fixture.html?controls';
const tab = await (await fetch(`${endpoint}/json/new?${fixture}`, { method: 'PUT' })).json();
const socket = new WebSocket(tab.webSocketDebuggerUrl);
await new Promise((resolve, reject) => { socket.onopen = resolve; socket.onerror = reject; });
let sequence = 0;
const pending = new Map();
const errors = [];
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
async function input(id, value, commit = false) {
  await evaluate(`(() => { const input = document.getElementById(${JSON.stringify(id)}); input.focus(); Object.getOwnPropertyDescriptor(HTMLInputElement.prototype, 'value').set.call(input, ${JSON.stringify(String(value))}); input.dispatchEvent(new Event('input', { bubbles: true })); ${commit ? `input.dispatchEvent(new KeyboardEvent('keyup', { key: 'Enter', bubbles: true }));` : ''} })()`);
  if (commit) await settled();
}
async function select(label, option, scope = 'document') {
  await evaluate(`(() => { const input = ${scope}.querySelector('input[role="combobox"][aria-label="${label}"]'); if (!input) throw new Error('Select not found: ${label}'); input.closest('.el-select').querySelector('.el-select__wrapper').click(); })()`);
  await pause(100);
  await evaluate(`(() => { const input = ${scope}.querySelector('input[role="combobox"][aria-label="${label}"]'); const option = [...input.closest('.el-select').querySelectorAll('[role="option"]')].find(el => el.textContent.trim() === ${JSON.stringify(option)}); if (!option) throw new Error('Option not found: ' + ${JSON.stringify(option)}); option.click(); })()`);
  await settled();
}
async function calls() { return evaluate(`JSON.parse(document.querySelector('#fixture-controls output').textContent).calls`); }
async function lastCall() { const list = await calls(); return list[list.length - 1]; }
async function screenshot(name) {
  await evaluate(`document.activeElement?.blur(); window.scrollTo(0, 0)`);
  await cdp('Input.dispatchMouseEvent', { type: 'mousePressed', x: 1, y: 1, button: 'left', clickCount: 1 });
  await cdp('Input.dispatchMouseEvent', { type: 'mouseReleased', x: 1, y: 1, button: 'left', clickCount: 1 });
  await evaluate(`document.querySelector('#fixture-controls').style.display = 'none'`);
  await pause(250);
  const result = await cdp('Page.captureScreenshot', { format: 'png', captureBeyondViewport: true, fromSurface: true });
  const path = new URL(`../test-results/${name}.png`, import.meta.url);
  await writeFile(path, Buffer.from(result.data, 'base64'));
  await evaluate(`document.querySelector('#fixture-controls').style.display = 'flex'`);
}

try {
  await cdp('Runtime.enable');
  await cdp('Emulation.setDeviceMetricsOverride', { width: 1280, height: 720, deviceScaleFactor: 1, mobile: false });
  await mkdir(new URL('../test-results/', import.meta.url), { recursive: true });
  await until(`document.querySelector('.footer-tabs') && !document.querySelector('.connection-state')`);
  await click('.footer-tabs button', '条件变换');
  assert.equal(await evaluate(`document.querySelectorAll('.condition-list-row').length`), 12);
  assert.equal(await evaluate(`document.querySelector('.condition-state').textContent`), '76.0%');

  // Polls preserve an unfinished number. A failed write preserves it for retry.
  await input('rule-hp-1-threshold', 37);
  await pause(1250);
  assert.equal(await evaluate(`document.getElementById('rule-hp-1-threshold').value`), '37');
  assert.equal((await calls()).length, 0);
  await click('#fixture-controls button', 'Fail next action');
  await evaluate(`document.getElementById('rule-hp-1-threshold').blur()`); await settled();
  assert.match(await evaluate(`document.querySelector('.error-banner').textContent`), /保存失败/);
  await pause(1100);
  assert.equal(await evaluate(`document.getElementById('rule-hp-1-threshold').value`), '37');
  await screenshot('conditions-save-error');
  await click('.condition-fields .el-button', '保存');
  assert.equal((await lastCall()).value, 37);
  assert.equal(await evaluate(`!!document.querySelector('.error-banner')`), false);
  await input('rule-hp-1-threshold', 101, true);
  assert.equal(await evaluate(`document.getElementById('rule-hp-1-threshold').getAttribute('aria-invalid')`), 'true');
  assert.equal((await lastCall()).value, 37);
  await input('rule-hp-1-threshold', 45, true);
  await input('condition-hp-test', 62.5); await click('.hp-test button', '设置 HP');
  assert.equal((await lastCall()).op, 'test_hp'); assert.equal((await lastCall()).value, 62.5);
  await click('.rule-toolbar button', '新增规则');
  assert.equal(await evaluate(`document.querySelector('.rule-tabs [aria-current="page"]').textContent.trim()`), '血量 3');
  await click('.condition-rule-remove button', '删除规则'); await click('.condition-rule-remove button', '确认删除');
  assert.equal((await lastCall()).op, 'rule_delete'); assert.equal((await lastCall()).rule, 3);

  // Single mode changes transform_type. Fixed states only edit their targets.
  await click('.condition-list .catalog-row', '武器拔刀状态›');
  assert.equal((await lastCall()).op, 'select'); assert.equal((await lastCall()).value, 'weapon');
  await click('.rule-tabs button', '拔刀');
  await click('.add-target', '新增目标');
  assert.equal((await lastCall()).rule, 2);
  await select('目标分组 1', '全局隐藏 · 全局组');
  assert.equal((await lastCall()).field, 'group'); assert.equal((await lastCall()).value, '全局隐藏');
  await select('目标预设 1', '隐藏徽章');
  assert.equal((await lastCall()).field, 'preset');
  await click('#fixture-controls button', 'Fail next action');
  await select('目标预设 1', '选择预设');
  await pause(1100);
  assert.equal(await evaluate(`document.querySelector('[aria-label="目标预设 1"]').closest('.el-select').querySelector('.el-select__placeholder').textContent`), '选择预设');
  assert.match(await evaluate(`document.querySelector('.error-banner').textContent`), /保存失败/);
  await click('.condition-target-row .condition-select .el-button', '保存');
  assert.equal(await evaluate(`!!document.querySelector('.error-banner')`), false);
  await click('.target-remove', '移除目标');
  assert.equal((await lastCall()).op, 'target_delete');

  // Parallel browsing never writes the single-mode selection.
  await click('.conditions-mode label', '并行');
  const beforeBrowse = (await calls()).length;
  await click('.condition-list .catalog-row', '受击3›');
  assert.equal((await calls()).length, beforeBrowse);
  await input('priority-damage', 17, true);
  assert.equal((await lastCall()).condition, 'damage'); assert.equal((await lastCall()).field, 'priority'); assert.equal((await lastCall()).value, 17);
  await click('.condition-list-row:nth-child(3) .el-checkbox');
  assert.equal((await lastCall()).field, 'enabled'); assert.equal((await lastCall()).condition, 'damage');
  assert.equal(await evaluate(`!!document.getElementById('rule-damage-1-loop_count')`), false);
  await select('动作模式', '循环');
  assert.equal((await lastCall()).value, 2);
  await input('rule-damage-1-loop_inactive_time', 2.5, true);
  await input('rule-damage-1-loop_count', 0, true);
  await screenshot('conditions-loop');
  await select('动作模式', '链式');
  assert.equal(await evaluate(`!!document.getElementById('rule-damage-1-duration')`), false);
  assert.equal(await evaluate(`document.querySelectorAll('.chain-node').length`), 1);
  await click('.condition-section-heading button', '新增节点');
  assert.equal(await evaluate(`document.querySelectorAll('.chain-node').length`), 2);
  await input('chain-damage-1-2', 2.25, true);
  assert.equal((await lastCall()).node, 2); assert.equal((await lastCall()).value, 2.25);
  await click('.chain-node:nth-of-type(2) .add-target', '新增目标');
  assert.equal((await lastCall()).node, 2);
  await select('目标分组 1', '上身', `document.querySelectorAll('.chain-node')[1]`);
  await select('目标预设 1', '无外套', `document.querySelectorAll('.chain-node')[1]`);
  assert.equal((await lastCall()).node, 2); assert.equal((await lastCall()).target, 1); assert.equal((await lastCall()).value, '无外套');
  await click('.condition-tests button', '受击测试（减少 25 HP）');
  assert.equal((await lastCall()).op, 'test_damage');
  await screenshot('conditions-chain');
  await click('.chain-node:nth-of-type(2) .chain-node-heading button', '移除节点');
  assert.equal((await lastCall()).op, 'chain_delete'); assert.equal((await lastCall()).node, 2);

  // Rise has its total toggle and numeric-state definitions, but no game HP test.
  await click('#fixture-controls button', 'English / Rise');
  await until(`document.querySelector('.condition-heading h2')?.textContent === 'Weapon state'`);
  assert.equal(await evaluate(`document.querySelectorAll('.condition-list-row').length`), 10);
  await click('.conditions-sidebar > .el-checkbox', 'Enable conditions');
  assert.equal((await lastCall()).op, 'enabled'); assert.equal((await lastCall()).value, false);
  await click('.condition-list .catalog-row', 'Monster HP›');
  await input('rule-monster_hp-1-threshold', 0, true);
  assert.equal((await lastCall()).value, 0);
  assert.equal(await evaluate(`!!document.querySelector('.condition-tests')`), false);
  await screenshot('conditions-rise');
  await cdp('Emulation.setDeviceMetricsOverride', { width: 700, height: 800, deviceScaleFactor: 1, mobile: false });
  await screenshot('conditions-rise-narrow');
  assert.equal(await evaluate(`document.documentElement.scrollWidth > innerWidth`), false);

  // Successful deletion retires only drafts whose array-index identity changed.
  await click('#fixture-controls button', 'Chinese / Wilds');
  await until(`document.querySelector('.condition-heading h2')?.textContent === '血量'`);
  await click('#fixture-controls button', 'Fail next action');
  await input('rule-hp-1-threshold', 67, true);
  assert.equal(await evaluate(`document.getElementById('rule-hp-1-threshold').value`), '67');
  await click('.condition-rule-remove button', '删除规则'); await click('.condition-rule-remove button', '确认删除');
  assert.equal(await evaluate(`document.getElementById('rule-hp-1-threshold').value`), '25');
  assert.equal(await evaluate(`!!document.querySelector('.condition-fields .el-button')`), false);
  await click('.condition-list .catalog-row', '受击›');
  await select('动作模式', '链式');
  await click('.condition-section-heading button', '新增节点');
  await input('chain-damage-1-2', 2.25, true);
  await click('#fixture-controls button', 'Fail next action');
  await input('chain-damage-1-1', 9, true);
  await click('.chain-node:nth-of-type(1) .chain-node-heading button', '移除节点');
  assert.equal(await evaluate(`document.getElementById('chain-damage-1-1').value`), '2.25');
  assert.equal(await evaluate(`!!document.querySelector('.chain-node > .condition-number .el-button')`), false);
  await click('.chain-node .add-target', '新增目标');
  await click('.chain-node .add-target', '新增目标');
  await select('目标分组 2', '上身');
  await select('目标预设 2', '无外套');
  await click('#fixture-controls button', 'Fail next action');
  await select('目标预设 1', '日常');
  await click('.target-remove[aria-label="移除目标 1"]', '移除目标');
  assert.equal(await evaluate(`document.querySelector('[aria-label="目标预设 1"]').closest('.el-select').querySelector('.el-select__placeholder').textContent`), '无外套');
  assert.equal(await evaluate(`!!document.querySelector('.condition-target-row .condition-select .el-button')`), false);
  await click('#fixture-controls button', 'Fail next action');
  await select('目标预设 1', '完整上装');
  await select('目标分组 1', '主预设');
  assert.equal(await evaluate(`document.querySelector('[aria-label="目标预设 1"]').closest('.el-select').querySelector('.el-select__placeholder').textContent`), '选择预设');
  assert.equal(await evaluate(`!!document.querySelector('.condition-target-row .condition-select .el-button')`), false);
  await click('#fixture-controls button', 'No character');
  await until(`!document.querySelector('.conditions-sidebar')`);
  assert.match(await evaluate(`document.querySelector('.conditions-workspace').textContent`), /等待角色与装备/);
  assert.equal((await evaluate(`JSON.parse(document.querySelector('#fixture-controls output').textContent)`)).peak, 1);
  assert.deepEqual(errors, []);
  console.log('Conditions browser fixture passed: drafts/polls, failed save + retry, structural deletion resets, targets, single/parallel, priorities, rules, all damage modes, chain nodes, tests, Rise toggle, empty character, narrow layout.');
} finally {
  socket.close();
  await fetch(`${endpoint}/json/close/${tab.id}`);
}
