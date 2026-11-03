import assert from 'node:assert/strict';
import { mkdir, writeFile } from 'node:fs/promises';

// Use a separate headless browser with its own profile, never a user's session.
const endpoint = process.argv[2];
if (!endpoint) throw new Error('Usage: node web/tests/settings-browser.mjs <CDP endpoint> [fixture URL]');
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
async function input(id, value, commit = false) {
  await evaluate(`(() => { const input = document.getElementById(${JSON.stringify(id)}); input.focus(); Object.getOwnPropertyDescriptor(HTMLInputElement.prototype, 'value').set.call(input, ${JSON.stringify(String(value))}); input.dispatchEvent(new Event('input', { bubbles: true })); ${commit ? `input.dispatchEvent(new KeyboardEvent('keyup', { key: 'Enter', bubbles: true }));` : ''} })()`);
  if (commit) await settled();
}
async function select(label, option) {
  await evaluate(`document.querySelector('input[role="combobox"][aria-label="${label}"]').closest('.el-select').querySelector('.el-select__wrapper').click()`);
  await pause(100);
  await evaluate(`(() => { const input = document.querySelector('input[role="combobox"][aria-label="${label}"]'); const option = [...input.closest('.el-select').querySelectorAll('[role="option"]')].find(el => el.textContent.trim() === ${JSON.stringify(option)}); if (!option) throw new Error('Option not found: ' + ${JSON.stringify(option)}); option.click(); })()`);
  await settled();
}
async function calls() { return evaluate(`JSON.parse(document.querySelector('#fixture-controls output').textContent).calls`); }
async function lastCall() { const list = await calls(); return list[list.length - 1]; }
async function names(pane) { return evaluate(`Array.from(document.querySelectorAll('.${pane} .row-name'), el => el.textContent.trim())`); }
async function startDrag(pane, source) {
  return evaluate(`(() => {
    const button = [...document.querySelectorAll('.${pane} .catalog-row')].find(el => el.querySelector('.row-name').textContent.trim() === ${JSON.stringify(source)});
    if (!button) throw new Error('Drag source not found');
    window.catalogDragTransfer = new DataTransfer();
    return button.dispatchEvent(new DragEvent('dragstart', { bubbles: true, cancelable: true, dataTransfer: window.catalogDragTransfer }));
  })()`);
}
async function drop(pane, source, target, after) {
  const accepted = await evaluate(`(() => {
    const rows = [...document.querySelectorAll('.${pane} .sortable-row')];
    const row = rows.find(el => el.querySelector('.row-name').textContent.trim() === ${JSON.stringify(target)});
    const rect = row.getBoundingClientRect(), dataTransfer = window.catalogDragTransfer;
    const options = { bubbles: true, cancelable: true, dataTransfer, clientY: rect.top + rect.height * ${after ? .75 : .25} };
    const accepted = !row.dispatchEvent(new DragEvent('dragover', options));
    row.dispatchEvent(new DragEvent('drop', options));
    rows.find(el => el.querySelector('.row-name').textContent.trim() === ${JSON.stringify(source)})?.querySelector('.catalog-row').dispatchEvent(new DragEvent('dragend', { bubbles: true, dataTransfer }));
    delete window.catalogDragTransfer;
    return accepted;
  })()`);
  await settled();
  return accepted;
}
async function drag(pane, source, target, after) {
  await startDrag(pane, source);
  return drop(pane, source, target, after);
}
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
async function checkCameraReset() {
  await input('setting-portrait_camera-distance', 4, true);
  await input('setting-portrait_camera-horizontal', .5, true);
  await evaluate(`document.activeElement?.blur()`); await settled();
  await click('#fixture-controls button', 'Fail next action');
  await click('[data-setting="portrait_camera.reset"] button', '重置镜头');
  assert.equal(await evaluate(`document.getElementById('setting-portrait_camera-distance').value`), '4');
  assert.match(await evaluate(`document.querySelector('.error-banner').textContent`), /保存失败/);
  await click('[data-setting="portrait_camera.reset"] button', '重置镜头');
  assert.deepEqual(await lastCall(), { kind: 'setting', id: 'portrait_camera.reset', bodyId: 'ch03_001_0000' });
  assert.equal(await evaluate(`document.getElementById('setting-portrait_camera-distance').value`), '2.8');
  assert.equal(await evaluate(`document.getElementById('setting-portrait_camera-horizontal').value`), '0');
}

try {
  await cdp('Runtime.enable');
  await cdp('Emulation.setDeviceMetricsOverride', { width: 1280, height: 850, deviceScaleFactor: 1, mobile: false });
  await mkdir(new URL('../test-results/', import.meta.url), { recursive: true });
  await until(`document.querySelector('.footer-tabs') && !document.querySelector('.connection-state')`);

  if (process.argv.includes('--game-settings-only')) {
    await click('.footer-tabs button', '设置');
    const scanning = ['scan_interval', 'body_id_ttl', 'scanner_batch_size'];
    assert.deepEqual(await evaluate(`Array.from(document.querySelectorAll('.settings-section[aria-label="装备扫描"] [data-setting]'), field => field.dataset.setting)`), scanning);
    for (const [id, value] of [['scan_interval', .7], ['body_id_ttl', 1.5], ['scanner_batch_size', 120]]) {
      await input('setting-' + id, value, true);
      assert.deepEqual(await lastCall(), { kind: 'setting', id, value, bodyId: 'ch03_001_0000' });
    }
    await screenshot('settings-wilds-scanning');
    await click('#fixture-controls button', 'English / Rise');
    await until(`!!document.querySelector('[data-setting="enable_multiplayer"]')`);
    assert.deepEqual(await evaluate(`Array.from(document.querySelectorAll('.settings-page .settings-section h3'), heading => heading.textContent.trim())`), ['Interface theme', 'General', 'Multiplayer', 'Dissolve transitions', 'Image quality']);
    for (const id of scanning) assert.equal(await evaluate(`document.querySelector('[data-setting="${id}"]') === null`), true);
    await select('Language', '简体中文');
    assert.deepEqual(await lastCall(), { kind: 'setting', id: 'language', value: 'zh', bodyId: 'ch03_001_0000' });
    await select('Language', 'English');
    assert.equal((await lastCall()).value, 'en');
    for (const [id, value] of [['enable_multiplayer', false], ['dissolve_enabled', false], ['enable_image_quality', true]]) {
      await click(`[data-setting="${id}"] .el-checkbox`);
      assert.deepEqual(await lastCall(), { kind: 'setting', id, value, bodyId: 'ch03_001_0000' });
    }
    for (const [id, value] of [['dissolve_duration', .45], ['image_quality_rate', 1.25]]) {
      await input('setting-' + id, value, true);
      assert.deepEqual(await lastCall(), { kind: 'setting', id, value, bodyId: 'ch03_001_0000' });
    }
    await screenshot('settings-rise-supported');
    assert.deepEqual(errors, []);
    console.log('Game settings fixture passed: Rise has no scanning fields or performance section; language, multiplayer, dissolve and image quality remain editable; Wilds retains all three working scanning fields.');
  } else if (process.argv.includes('--reset-only')) {
    await click('.footer-tabs button', '设置');
    await checkCameraReset();
    await screenshot('settings-ice-cyan');
    await click('#fixture-controls button', 'Preview unavailable');
    await until(`document.querySelector('[data-setting="portrait_camera.reset"] button').disabled`);
    assert.equal(await evaluate(`document.querySelectorAll('.settings-page .setting-reason').length`), 1);
    await click('.theme-settings .el-radio', '跟随 REFF');
    await click('#fixture-controls button', 'REFF amber');
    await screenshot('settings-reff-amber');
    await click('#fixture-controls button', 'English / Rise');
    await until(`!!document.querySelector('[data-setting="enable_multiplayer"]')`);
    await screenshot('settings-rise');
    await cdp('Emulation.setDeviceMetricsOverride', { width: 700, height: 850, deviceScaleFactor: 1, mobile: false });
    await click('#fixture-controls button', 'REFF violet / 140%');
    await screenshot('settings-reff-narrow');
    assert.equal(await evaluate(`document.documentElement.scrollWidth > innerWidth`), false);
    assert.deepEqual(errors, []);
    console.log('Camera action fixture passed: reset sends no value, failure keeps all camera fields, successful retry refreshes defaults, disabled capability; inspected shared-reason rendering and translated 140% narrow layout.');
  } else {

  // Direct dragging never moves the main/global region or changes the active selection.
  assert.equal(await evaluate(`document.querySelector('.sort-toggle') === null`), true);
  assert.deepEqual(await names('groups-pane'), ['主预设', '全局隐藏', '上身', '腰部装饰']);
  assert.deepEqual(await evaluate(`Array.from(document.querySelectorAll('.groups-pane .catalog-row'), el => el.draggable)`), [false, false, true, true]);
  let beforeSorting = (await calls()).length;
  assert.equal(await startDrag('groups-pane', '全局隐藏'), false);
  assert.equal(await drop('groups-pane', '全局隐藏', '上身', true), false);
  assert.equal(await drag('groups-pane', '上身', '主预设', true), false);
  assert.equal(await drag('groups-pane', '上身', '全局隐藏', true), false);
  assert.equal((await calls()).length, beforeSorting);
  assert.equal(await drag('groups-pane', '上身', '腰部装饰', true), true);
  assert.deepEqual(await names('groups-pane'), ['主预设', '全局隐藏', '腰部装饰', '上身']);
  assert.deepEqual(await lastCall(), { kind: 'reorder-group', name: '上身', target: '腰部装饰', after: true, group: '上身', weapon: false, bodyId: 'ch03_001_0000' });
  assert.equal(await evaluate(`document.querySelector('.groups-pane .catalog-row[aria-pressed="true"] .row-name').textContent`), '上身');
  await click('#fixture-controls button', 'Fail next action');
  await drag('groups-pane', '上身', '腰部装饰', false);
  assert.deepEqual(await names('groups-pane'), ['主预设', '全局隐藏', '腰部装饰', '上身']);
  assert.match(await evaluate(`document.querySelector('.error-banner').textContent`), /保存失败/);
  await drag('presets-pane', '无外套', '完整上装', false);
  assert.deepEqual(await names('presets-pane'), ['无外套', '完整上装', '内衬']);
  assert.equal((await lastCall()).kind, 'reorder-preset');
  assert.equal(await evaluate(`document.querySelector('.presets-pane .catalog-row[aria-pressed="true"] .row-name').textContent`), '无外套');
  await click('#fixture-controls button', 'Fail next action');
  await drag('presets-pane', '无外套', '内衬', true);
  assert.deepEqual(await names('presets-pane'), ['无外套', '完整上装', '内衬']);
  await evaluate(`document.querySelector('.presets-pane .catalog-row').dispatchEvent(new KeyboardEvent('keydown', { key: 'ArrowDown', altKey: true, bubbles: true, cancelable: true }))`);
  await settled();
  assert.deepEqual(await names('presets-pane'), ['完整上装', '无外套', '内衬']);
  beforeSorting = (await calls()).length;
  await startDrag('groups-pane', '上身');
  await click('#fixture-controls button', 'Other equipment');
  await until(`document.querySelector('.equipment-id').textContent === 'ch03_002_0000'`);
  assert.equal(await drop('groups-pane', '上身', '腰部装饰', false), false);
  assert.equal((await calls()).length, beforeSorting);
  await click('#fixture-controls button', 'Restore character');
  await until(`document.querySelector('.equipment-id').textContent === 'ch03_001_0000'`);
  await screenshot('sorting-ice-cyan');

  await click('.footer-tabs button', '设置');
  assert.equal(await evaluate(`document.querySelectorAll('.settings-page .settings-section').length`), 4);
  await screenshot('settings-ice-cyan');
  await checkCameraReset();
  // Polling preserves numeric drafts, including failed saves and a retry.
  await input('setting-scan_interval', .7);
  await pause(1200);
  assert.equal(await evaluate(`document.getElementById('setting-scan_interval').value`), '0.7');
  await click('#fixture-controls button', 'Fail next action');
  await evaluate(`document.getElementById('setting-scan_interval').blur()`); await settled();
  await pause(1100);
  assert.equal(await evaluate(`document.getElementById('setting-scan_interval').value`), '0.7');
  await click('[data-setting="scan_interval"] .el-button', '保存');
  assert.deepEqual(await lastCall(), { kind: 'setting', id: 'scan_interval', value: .7, bodyId: 'ch03_001_0000' });
  await input('setting-scan_interval', 6, true);
  assert.equal(await evaluate(`document.getElementById('setting-scan_interval').getAttribute('aria-invalid')`), 'true');
  assert.equal((await lastCall()).value, .7);
  await input('setting-scan_interval', .8, true);

  await click('#fixture-controls button', 'Fail next action');
  await click('[data-setting="auto_set_selected_preset_as_default"] .el-checkbox');
  await pause(1100);
  assert.equal(await evaluate(`document.querySelector('[data-setting="auto_set_selected_preset_as_default"] input').checked`), true);
  await click('[data-setting="auto_set_selected_preset_as_default"] .el-button', '保存');
  assert.equal((await lastCall()).value, true);
  await select('预览刷新率', '全速');
  assert.equal((await lastCall()).value, 0);
  assert.equal(await evaluate(`document.querySelector('.settings-page [data-setting="ground_clipping_height_cm"]')`), null);
  await click('.footer-tabs button', '部件材质');
  await input('setting-ground_clipping_height_cm', 12.5, true);
  assert.equal((await lastCall()).bodyId, 'ch03_001_0000');
  assert.match(await evaluate(`document.querySelector('.height-pane').textContent`), /预设草稿/);

  // All global settings remain usable without a character; equipment does not.
  await click('#fixture-controls button', 'No character');
  await until(`document.querySelector('.equipment-id').textContent === '—'`);
  assert.equal(await evaluate(`document.getElementById('setting-ground_clipping_height_cm').disabled`), true);
  await click('.footer-tabs button', '设置');
  assert.equal(await evaluate(`document.getElementById('setting-scan_interval').disabled`), false);
  await input('setting-body_id_ttl', 1.5, true);
  assert.equal((await lastCall()).bodyId, '');
  await click('#fixture-controls button', 'Preview unavailable');
  await until(`document.getElementById('setting-portrait_camera-distance').disabled`);
  assert.match(await evaluate(`document.querySelector('.settings-section[aria-label="预览相机"]').textContent`), /预览模块未加载/);

  // Theme preferences remain local to AVM; inspect REFF tokens and scaled/narrow layout.
  await click('.theme-settings .el-radio', '跟随 REFF');
  await click('#fixture-controls button', 'REFF amber');
  await screenshot('settings-reff-amber');
  await click('#fixture-controls button', 'English / Rise');
  await until(`!!document.querySelector('[data-setting="enable_multiplayer"]')`);
  assert.equal(await evaluate(`!!document.querySelector('[data-setting="portrait_enabled"]')`), false);
  await click('[data-setting="enable_multiplayer"] .el-checkbox');
  assert.equal((await lastCall()).id, 'enable_multiplayer');
  await input('setting-dissolve_duration', .45, true);
  await input('setting-image_quality_rate', 1.25, true);
  assert.equal((await lastCall()).value, 1.25);
  await screenshot('settings-rise');
  await cdp('Emulation.setDeviceMetricsOverride', { width: 700, height: 850, deviceScaleFactor: 1, mobile: false });
  await click('#fixture-controls button', 'REFF violet / 140%');
  await screenshot('settings-reff-narrow');
  assert.equal(await evaluate(`document.documentElement.scrollWidth > innerWidth`), false);
  assert.equal((await evaluate(`JSON.parse(document.querySelector('#fixture-controls output').textContent)`)).peak, 1);
  assert.deepEqual(errors, []);
  console.log('Settings/sorting browser fixture passed: bounded ordering and failed-write stability, numeric/boolean drafts and retry, global settings without character, scoped height draft, disabled preview, both games, REFF/custom themes, narrow 140% layout, serial transport.');
  }
} finally {
  socket.close();
  await fetch(`${endpoint}/json/close/${tab.id}`);
}
