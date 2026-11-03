import { test } from 'node:test';
import assert from 'node:assert/strict';
import { normalizeDocumentation, normalizeSnapshot } from '../src/snapshot.ts';

test('normalizes the REFramework empty-table shapes at the snapshot boundary', () => {
  for (const empty of [null, {}]) {
    const result = normalizeSnapshot({ groups: empty, presets: empty, parts: empty, pending: null });
    assert.deepEqual(result, { groups: [], presets: [], parts: [], pending: {}, conditions: null, backupPending: false });
    const nested = normalizeSnapshot({ groups: [], presets: [], parts: [{ index: 1, materials: [{ name: 'body', groups: empty }] }, { index: 2, materials: empty }], pending: { 1: null } });
    assert.deepEqual(nested.parts[0].materials[0].groups, []);
    assert.deepEqual(nested.parts[1].materials, []);
    assert.deepEqual(nested.pending, { 1: {} });
  }
});
test('preserves nonempty arrays and surfaces a nonempty object in an array field', () => {
  const value = { groups: [{ name: 'a', global: true }], presets: [{ name: 'one', default: true }], parts: [{ index: 2, materials: [{ name: 'x', enabled: false, groups: ['a'] }] }], pending: { 2: { x: true } } };
  assert.deepEqual(normalizeSnapshot(value), { ...value, conditions: null, backupPending: false });
  assert.throws(() => normalizeSnapshot({ ...value, parts: { wrong: true } }), /parts must be an array/);
});

test('preserves the backup warning and defaults older snapshots to no warning', () => {
  const value = { groups: [], presets: [], parts: [] };
  assert.equal(normalizeSnapshot(value).backupPending, false);
  assert.equal(normalizeSnapshot({ ...value, backupPending: true }).backupPending, true);
  assert.equal(normalizeSnapshot({ ...value, backupPending: false }).backupPending, false);
});

test('normalizes Lua documentation arrays and preserves plain text, stable ids and ordering', () => {
  for (const empty of [null, {}]) {
    assert.deepEqual(normalizeDocumentation({ sections: empty }), { sections: [] });
    assert.deepEqual(normalizeDocumentation({ sections: [{ id: 'configure', title: '如何配置', entries: empty }] }), { sections: [{ id: 'configure', title: '如何配置', entries: [] }] });
    assert.deepEqual(normalizeDocumentation({ sections: [{ id: 'usage', title: '使用说明', entries: [{ title: '分组', paragraphs: empty }] }] }).sections[0].entries[0].paragraphs, []);
  }
  const value = { sections: [{ id: 'configure', title: '如何配置', entries: [{ title: '普通组', paragraphs: ['保留 <literal> & 普通文本。', 'line one\nline two'] }] }, { id: 'usage', title: '使用说明', entries: [] }, { id: 'changelog', title: '更新日志', entries: [] }] };
  assert.deepEqual(normalizeDocumentation(value), value);
  assert.throws(() => normalizeDocumentation({ sections: { wrong: true } }), /documentation.sections must be an array/);
  assert.throws(() => normalizeDocumentation({ sections: [{ entries: [{ paragraphs: { wrong: true } }] }] }), /documentation.paragraphs must be an array/);
});

test('normalizes empty condition tables without changing rule fields or target references', () => {
  for (const empty of [null, {}]) {
    const conditions = { enabled: true, parallel: false, selected: 'damage',
      targets: [{ name: '上身', presets: empty }],
      definitions: [{ id: 'damage', fields: [{ key: 'mode', kind: 'select', options: empty, modes: empty }],
        rules: [{ index: 1, mode: 3, custom: 'retained', targets: empty, chain_nodes: [{ index: 1, duration: 2, targets: empty }] }] }] };
    const result = normalizeSnapshot({ groups: [], presets: [], parts: [], conditions });
    assert.deepEqual(result.conditions.targets[0].presets, []);
    assert.deepEqual(result.conditions.definitions[0].fields[0].options, []);
    assert.deepEqual(result.conditions.definitions[0].fields[0].modes, []);
    assert.deepEqual(result.conditions.definitions[0].rules[0], { index: 1, mode: 3, custom: 'retained', targets: [], chain_nodes: [{ index: 1, duration: 2, targets: [] }] });
    assert.deepEqual(normalizeSnapshot({ groups: [], presets: [], parts: [], conditions: { targets: empty, definitions: empty } }).conditions, { targets: [], definitions: [] });
  }
});

test('normalizes settings schema arrays without changing values, capabilities or order', () => {
  for (const empty of [null, {}]) {
    const base = { groups: [], presets: [], parts: [] };
    assert.deepEqual(normalizeSnapshot({ ...base, settings: { sections: empty } }).settings, { sections: [] });
    const settings = { sections: [{ id: 'global', scope: 'global', fields: empty }, { id: 'portrait', scope: 'global', fields: [
      { id: 'portrait_camera.refresh_fps', type: 'select', value: 0, options: empty, disabled: true, reason: 'Preview unavailable' },
      { id: 'scan_interval', type: 'number', value: .3, min: .1, max: 5, step: .1 },
      { id: 'portrait_camera.reset', type: 'action', label: 'Reset camera' },
    ] }] };
    const result = normalizeSnapshot({ ...base, settings }).settings;
    assert.deepEqual(result.sections.map(section => section.id), ['global', 'portrait']);
    assert.deepEqual(result.sections[0].fields, []);
    assert.deepEqual(result.sections[1].fields[0], { ...settings.sections[1].fields[0], options: [] });
    assert.deepEqual(result.sections[1].fields[1], settings.sections[1].fields[1]);
    assert.deepEqual(result.sections[1].fields[2], settings.sections[1].fields[2]);
    assert.throws(() => normalizeSnapshot({ ...base, settings: { sections: { wrong: true } } }), /settings.sections must be an array/);
  }
});
