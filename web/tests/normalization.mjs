import { test } from 'node:test';
import assert from 'node:assert/strict';
import { normalizeSnapshot } from '../src/snapshot.ts';

test('normalizes the REFramework empty-table shapes at the snapshot boundary', () => {
  for (const empty of [null, {}]) {
    const result = normalizeSnapshot({ groups: empty, presets: empty, parts: empty, pending: null });
    assert.deepEqual(result, { groups: [], presets: [], parts: [], pending: {} });
    const nested = normalizeSnapshot({ groups: [], presets: [], parts: [{ index: 1, materials: [{ name: 'body', groups: empty }] }, { index: 2, materials: empty }], pending: { 1: null } });
    assert.deepEqual(nested.parts[0].materials[0].groups, []);
    assert.deepEqual(nested.parts[1].materials, []);
    assert.deepEqual(nested.pending, { 1: {} });
  }
});
test('preserves nonempty arrays and surfaces a nonempty object in an array field', () => {
  const value = { groups: [{ name: 'a', global: true }], presets: [{ name: 'one', default: true }], parts: [{ index: 2, materials: [{ name: 'x', enabled: false, groups: ['a'] }] }], pending: { 2: { x: true } } };
  assert.deepEqual(normalizeSnapshot(value), value);
  assert.throws(() => normalizeSnapshot({ ...value, parts: { wrong: true } }), /parts must be an array/);
});
