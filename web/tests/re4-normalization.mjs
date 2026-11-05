import { test } from 'node:test';
import assert from 'node:assert/strict';
import { normalizeRe4 as normalizeSnapshot } from '../src/re4/snapshot.ts';

const settings = { weaponHideStorage: false, uiDissolveEnabled: true, uiDissolveTime: 1 };

test('fills RE4 defaults without adding MH fields', () => {
  const re4 = normalizeSnapshot({ game: 'RE4', version: '4.3.4', language: 'zh', settings, characters: null, character: '' });
  assert.deepEqual(re4, { game: 'RE4', version: '4.3.4', language: 'zh', settings, characters: [], character: '' });
  assert.equal('groups' in re4, false, 'RE4 snapshots never gain MH fields');
});

test('normalizes the REFramework empty-table shapes inside RE4 layers, rules and conditions', () => {
  for (const empty of [null, {}]) {
    const layer = { name: 'Face', base: false, presets: empty, active: '', fromRule: false, auto: true, advanced: true,
      rules: [{ index: 1, preset: 'Hurt', priority: 1, logic: 'AND', hold: 0, conditions: empty, hits: false, effective: false, orphan: false,
        dissolve: { enabled: false, hideTime: .5, showTime: .5 }, hpDrive: { enabled: true, upper: 100, lower: 0, invert: false } }] };
    const result = normalizeSnapshot({ game: 'RE4', version: '1', language: 'en', settings, character: 'Leon',
      characters: [{ id: 'Leon', label: 'Leon', configured: true, targets: empty }],
      status: { hp: 50, flags: empty }, conditions: [{ id: 'hp_ratio', kind: 'number', label: 'HP', ops: empty }],
      base: { ...layer, name: 'Full outfit', base: true, rules: empty }, axes: [layer] });
    assert.deepEqual(result.characters[0].targets, []);
    assert.deepEqual(result.status.flags, []);
    assert.deepEqual(result.conditions[0].ops, []);
    assert.deepEqual(result.base.rules, []);
    assert.deepEqual(result.axes[0].presets, []);
    assert.deepEqual(result.axes[0].rules[0].conditions, []);
  }
});

test('surfaces a malformed RE4 list instead of rendering a partial page', () => {
  assert.throws(() => normalizeSnapshot({ game: 'RE4', version: '1', language: 'zh', settings, character: '', characters: { wrong: true } }),
    /characters must be an array/);
});

test('normalizes phase-2 editor, preset values and saves when Lua sends empty tables', () => {
  const base = { name: 'Full outfit', base: true, presets: ['A', 'B'], active: 'A', fromRule: false, auto: true, advanced: false,
    rules: null, values: { A: { body: { Skin: true } }, B: null }, match: { A: { status: 'partial', skipped: null }, B: null } };
  const axis = { name: 'Face', base: false, presets: ['1'], active: '1', fromRule: false, auto: true, advanced: false, rules: null, values: null };
  const result = normalizeSnapshot({ game: 'RE4', version: '1', language: 'zh', settings, character: 'Leon', characters: [],
    base, axes: [axis],
    editor: { armorMirror: false, slots: [{ id: 'body', label: 'Body', mirrored: false, materials: null }], conflicts: null },
    saves: { slots: null, hasBackup: false, hasOnload: true }, ownership: { shared: false, canReset: true, canMatchKin: false } });
  assert.deepEqual(result.base.values, { A: { body: { Skin: true } }, B: {} });
  assert.deepEqual(result.base.match.A.skipped, []);
  assert.deepEqual(result.axes[0].values, {});
  assert.equal('match' in result.axes[0], false, 'state groups have no slot-match gate');
  assert.deepEqual(result.editor.slots[0].materials, []);
  assert.deepEqual(result.editor.conflicts, []);
  assert.deepEqual(result.saves.slots, []);
});
