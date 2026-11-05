import { test } from 'node:test';
import assert from 'node:assert/strict';
import { normalizeRe4 as normalizeSnapshot } from '../src/re4/snapshot.ts';

const settings = { weaponHideStorage: false, uiDissolveEnabled: true, uiDissolveTime: 1 };

test('fills RE4 defaults without adding MH fields', () => {
  const re4 = normalizeSnapshot({ game: 'RE4', version: '4.3.4', language: 'zh', settings, characters: null, character: '' });
  assert.deepEqual(re4, { game: 'RE4', version: '4.3.4', language: 'zh', settings, characters: [], character: '' });
  assert.equal('groups' in re4, false, 'RE4 snapshots never gain MH fields');
});

test('a v2 config only carries the migration entry', () => {
  const re4 = normalizeSnapshot({ game: 'RE4', version: '1', language: 'en', settings, character: 'Leon', configVersion: 2,
    characters: [{ id: 'Leon', label: 'Leon', configured: true, targets: null }], notice: null });
  assert.equal(re4.configVersion, 2);
  assert.equal('notice' in re4, false);
  assert.equal(re4.base, undefined);
  assert.deepEqual(re4.characters[0].targets, []);
});

test('normalizes the REFramework empty-table shapes inside the v3 snapshot', () => {
  for (const empty of [null, {}]) {
    const result = normalizeSnapshot({ game: 'RE4', version: '1', language: 'en', settings, character: 'Leon', configVersion: 3,
      characters: [{ id: 'Leon', label: 'Leon', configured: true, targets: empty }],
      status: { hp: 50, flags: empty }, conditions: [{ id: 'hp_ratio', kind: 'number', label: 'HP', category: 'hp', ops: empty }],
      slots: [{ id: 'body', label: 'Body', mirrored: false, materials: empty }], look: empty,
      base: { active: null, presets: [{ name: 'A', values: empty, match: { status: 'ok', skipped: empty } }] },
      groups: [{ name: 'G', scope: empty, active: null, options: [{ name: 'o', values: empty }] }],
      states: [{ name: 's', enabled: true, exclusive: false, logic: 'AND', hold: 0, fadeIn: 0, fadeOut: 0, kind: 'idle', targets: empty, conditions: empty }],
      presets: { current: 'full', dismissed: false, list: empty, better: empty, autosaves: empty } });
    assert.deepEqual(result.characters[0].targets, []);
    assert.deepEqual(result.status.flags, []);
    assert.deepEqual(result.conditions[0].ops, []);
    assert.deepEqual(result.slots[0].materials, []);
    assert.deepEqual(result.look, []);
    assert.equal(result.base.active, '');
    assert.deepEqual(result.base.presets[0].values, {});
    assert.deepEqual(result.base.presets[0].match.skipped, []);
    assert.deepEqual(result.groups[0].scope, []);
    assert.equal(result.groups[0].active, '');
    assert.deepEqual(result.groups[0].options[0].values, {});
    assert.deepEqual(result.states[0].targets, []);
    assert.deepEqual(result.states[0].conditions, []);
    assert.equal(result.states[0].holding, false);
    assert.deepEqual(result.presets.list, []);
    assert.deepEqual(result.presets.autosaves, []);
  }
});

test('rejects a non-list where a list is required', () => {
  assert.throws(() => normalizeSnapshot({ game: 'RE4', version: '1', language: 'en', settings, character: '', characters: 'x' }));
});
