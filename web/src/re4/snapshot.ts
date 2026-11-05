import type {
  Re4BasePreset, Re4Character, Re4ConditionDef, Re4Group, Re4Look, Re4Option, Re4PresetEntry, Re4Slot, Re4Snapshot, Re4State,
} from './types';

// REFramework 把空 Lua 表序列化成 null（有的编码器给 {}）；缺省字段按空处理。
function list<T>(value: unknown, field: string): T[] {
  if (Array.isArray(value)) return value;
  if (value === null || value === undefined || (typeof value === 'object' && Object.keys(value).length === 0)) return [];
  throw new Error(`Invalid RE4 snapshot: ${field} must be an array`);
}
const record = <T>(value: unknown): Record<string, T> =>
  value && typeof value === 'object' && !Array.isArray(value) ? value as Record<string, T> : {};

function state(value: Re4State): Re4State {
  return { ...value, holding: value.holding === true,
    targets: list(value.targets, 'state.targets'), conditions: list(value.conditions, 'state.conditions') };
}

export function normalizeRe4(value: Re4Snapshot): Re4Snapshot {
  const out: Re4Snapshot = {
    ...value,
    characters: list<Re4Character>(value.characters, 'characters').map(item => ({ ...item, targets: list<string>(item.targets, 'character.targets') })),
    character: value.character ?? '',
  };
  if (value.notice === null) delete out.notice;
  if (value.status) out.status = { ...value.status, flags: list<string>(value.status.flags, 'status.flags') };
  if (value.conditions !== undefined) {
    out.conditions = list<Re4ConditionDef>(value.conditions, 'conditions').map(def => ({
      ...def,
      ...(def.ops !== undefined ? { ops: list(def.ops, 'condition.ops') } : {}),
      ...(def.options !== undefined ? { options: list(def.options, 'condition.options') } : {}),
    }));
  }
  if (value.slots !== undefined) {
    out.slots = list<Re4Slot>(value.slots, 'slots').map(slot => ({ ...slot, materials: list(slot.materials, 'slot.materials') }));
  }
  if (value.look !== undefined) out.look = list<Re4Look>(value.look, 'look');
  if (value.base) {
    out.base = { ...value.base, active: value.base.active ?? '',
      presets: list<Re4BasePreset>(value.base.presets, 'base.presets').map(p => ({ ...p, values: record(p.values),
        match: { ...p.match, skipped: list<string>(p.match?.skipped, 'match.skipped') } })) };
  }
  if (value.groups !== undefined) {
    out.groups = list<Re4Group>(value.groups, 'groups').map(g => ({ ...g, active: g.active ?? '',
      scope: list<string>(g.scope, 'group.scope'),
      options: list<Re4Option>(g.options, 'group.options').map(o => ({ ...o, values: record(o.values) })) }));
  }
  if (value.states !== undefined) out.states = list<Re4State>(value.states, 'states').map(state);
  if (value.presets) {
    out.presets = { ...value.presets, dismissed: value.presets.dismissed === true,
      list: list<Re4PresetEntry>(value.presets.list, 'presets.list'),
      better: list(value.presets.better, 'presets.better'), autosaves: list(value.presets.autosaves, 'presets.autosaves') };
  }
  return out;
}
