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
      groups: [{ name: 'G', active: null, options: [{ name: 'o', values: empty }] }],
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

test('palette snapshot survives the REFramework empty-table shapes (null / {} for empty arrays)', () => {
  for (const empty of [null, {}]) {
    const result = normalizeSnapshot({ game: 'RE4', version: '1', language: 'zh', settings, character: 'Leon', configVersion: 3, characters: [],
      palette: {
        materials: [{ key: 'body/Skin', slot: 'body', material: 'Skin', main: 'p', addons: empty, missing: empty, overridden: 0 },
                    { key: 'hair/Hair', slot: 'hair', material: 'Hair', addons: empty, missing: empty, generic: empty, overridden: 2 }],
        profiles: { p: { id: 'p', label: { zh: 'P' }, enums: empty, groups: [{ id: 'g', tier: 'basic', params: [{ param: 'A', kind: 'enum', options: empty }] }] } },
        values: { 'body/Skin': empty }, overrides: { 'body/Skin': false, 'hair/Hair': empty }, selected: empty, errors: empty,
      } });
    const pal = result.palette;
    assert.deepEqual(pal.materials[0].addons, []);
    assert.deepEqual(pal.materials[0].missing, []);
    assert.deepEqual(pal.materials[1].generic, []);
    assert.deepEqual(pal.profiles.p.enums, {});
    assert.deepEqual(pal.profiles.p.groups[0].params[0].options, []);
    assert.deepEqual(pal.values['body/Skin'], {});
    assert.equal(pal.overrides['body/Skin'], false);
    assert.deepEqual(pal.overrides['hair/Hair'], {});
    assert.deepEqual(pal.selected, []);
    assert.deepEqual(pal.errors, []);
  }
  const bare = normalizeSnapshot({ game: 'RE4', version: '1', language: 'zh', settings, character: 'Leon', configVersion: 3, characters: [],
    palette: { error: 'boom', materials: null, profiles: null, values: null, overrides: null, selected: null, errors: null } }).palette;
  assert.equal(bare.error, 'boom');
  assert.deepEqual(bare.materials, []);
});

test('colour schemes survive empty-table shapes; the edited scheme defaults to always-on', () => {
  for (const empty of [null, {}]) {
    const result = normalizeSnapshot({ game: 'RE4', version: '1', language: 'zh', settings, character: 'Leon', configVersion: 3, characters: [],
      palettes: { list: empty, active: empty }, palette: { materials: null, profiles: null, values: null, overrides: null, selected: null, errors: null } });
    assert.deepEqual(result.palettes, { list: [], active: [], selected: '' });
    assert.equal(result.palette.scheme, '');
  }
  const one = normalizeSnapshot({ game: 'RE4', version: '1', language: 'zh', settings, character: 'Leon', configVersion: 3, characters: [],
    palettes: { list: [{ name: 'Pale', used: 2, materials: 1 }], active: ['Pale'] } });
  assert.deepEqual(one.palettes.list, [{ name: 'Pale', used: 2, materials: 1 }]);
});

test('hotkeys survive empty-table shapes (null skip lists, null list)', () => {
  for (const empty of [null, {}]) {
    const r = normalizeSnapshot({ game: 'RE4', version: '1', language: 'zh', settings, character: 'Leon', configVersion: 3, characters: [],
      hotkeys: [{ digit: 2, kind: 'group', group: 'Face', cycle: true, skip: empty }, { digit: 1, kind: 'base', option: 'A', cycle: false, skip: empty }] });
    assert.deepEqual(r.hotkeys[0].skip, []);
    assert.equal(r.hotkeys[1].cycle, false);
    assert.deepEqual(normalizeSnapshot({ game: 'RE4', version: '1', language: 'zh', settings, character: 'Leon', configVersion: 3, characters: [], hotkeys: empty }).hotkeys, []);
  }
});
