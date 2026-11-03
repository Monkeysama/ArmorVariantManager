import { test } from 'node:test';
import assert from 'node:assert/strict';
import { normalizeSnapshot } from '../src/snapshot.ts';

test('normalizes the REFramework empty-table shapes at the snapshot boundary', () => {
  for (const empty of [null, {}]) {
    const result = normalizeSnapshot({ groups: empty, presets: empty, parts: empty, pending: null });
    assert.deepEqual(result, { groups: [], presets: [], parts: [], pending: {}, conditions: null });
    const nested = normalizeSnapshot({ groups: [], presets: [], parts: [{ index: 1, materials: [{ name: 'body', groups: empty }] }, { index: 2, materials: empty }], pending: { 1: null } });
    assert.deepEqual(nested.parts[0].materials[0].groups, []);
    assert.deepEqual(nested.parts[1].materials, []);
    assert.deepEqual(nested.pending, { 1: {} });
  }
});
test('preserves nonempty arrays and surfaces a nonempty object in an array field', () => {
  const value = { groups: [{ name: 'a', global: true }], presets: [{ name: 'one', default: true }], parts: [{ index: 2, materials: [{ name: 'x', enabled: false, groups: ['a'] }] }], pending: { 2: { x: true } } };
  assert.deepEqual(normalizeSnapshot(value), { ...value, conditions: null });
  assert.throws(() => normalizeSnapshot({ ...value, parts: { wrong: true } }), /parts must be an array/);
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
