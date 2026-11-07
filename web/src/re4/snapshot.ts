import type {
  Re4BasePreset, Re4Character, Re4Hotkey, Re4ConditionDef, Re4Group, Re4Look, Re4Option, Re4Palette, Re4PaletteEntry, Re4PaletteGroup,
  Re4PaletteMaterial, Re4PaletteOption, Re4PaletteOverride, Re4PaletteProfile, Re4PaletteScheme, Re4PaletteSection, Re4PaletteValue, Re4PresetEntry, Re4Slot, Re4Snapshot, Re4State,
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

// 调色数据:Lua 的空表(没有附加映射、没有缺的参数、还没选材质……)到这里是 null 或 {},全部补成空数组 / 空表
function palette(value: Re4Palette): Re4Palette {
  const profiles: Re4Palette['profiles'] = {};
  for (const [id, p] of Object.entries(record<Re4PaletteProfile>(value.profiles))) {
    const enums: Record<string, Re4PaletteOption[]> = {};
    for (const [name, opts] of Object.entries(record<Re4PaletteOption[]>(p.enums))) enums[name] = list(opts, 'palette.enum');
    profiles[id] = { ...p, addon: p.addon === true, enums, sections: list<Re4PaletteSection>(p.sections, 'palette.sections'),
      groups: list<Re4PaletteGroup>(p.groups, 'palette.groups').map(g => ({ ...g,
        params: list<Re4PaletteEntry>(g.params, 'palette.params').map(e => ({ ...e,
          ...(e.options !== undefined ? { options: list(e.options, 'palette.options') } : {}) })) })) };
  }
  const values: Re4Palette['values'] = {};
  for (const [key, v] of Object.entries(record<Record<string, Re4PaletteValue>>(value.values))) values[key] = record(v);
  const overrides: Re4Palette['overrides'] = {};
  for (const [key, o] of Object.entries(record<Record<string, Re4PaletteOverride> | false>(value.overrides))) overrides[key] = o === false ? false : record(o);
  return { ...value, profiles, values, overrides,
    materials: list<Re4PaletteMaterial>(value.materials, 'palette.materials').map(m => ({ ...m,
      addons: list<string>(m.addons, 'material.addons'), missing: list<string>(m.missing, 'material.missing'),
      // 没有主映射的材质走通用兜底:一定给一个列表(没有 *Color 参数时 Lua 发来的是空表 → null)
      generic: m.main ? undefined : list<string>(m.generic, 'material.generic'),
      overridden: Number(m.overridden) || 0 })),
    selected: list<string>(value.selected, 'palette.selected'), errors: list<string>(value.errors, 'palette.errors'),
    scheme: typeof value.scheme === 'string' ? value.scheme : '' };
}

export function normalizeRe4(value: Re4Snapshot): Re4Snapshot {
  const out: Re4Snapshot = {
    ...value,
    characters: list<Re4Character>(value.characters, 'characters').map(item => ({ ...item, targets: list<string>(item.targets, 'character.targets') })),
    character: value.character ?? '',
  };
  if (value.notice === null) delete out.notice;
  if (value.preview === null) delete out.preview;
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
      options: list<Re4Option>(g.options, 'group.options').map(o => ({ ...o, values: record(o.values) })) }));
  }
  if (value.states !== undefined) out.states = list<Re4State>(value.states, 'states').map(state);
  if (value.palette) out.palette = palette(value.palette);
  // 快捷键:没有绑定 / 没有跳过的项时 Lua 发来空表 → null
  if (value.hotkeys !== undefined) {
    out.hotkeys = list<Re4Hotkey>(value.hotkeys, 'hotkeys').map(h => ({ ...h, cycle: h.cycle === true, skip: list<string>(h.skip, 'hotkey.skip') }));
  }
  // 调色方案:没有方案 / 没有生效的方案时 Lua 发来空表 → null
  if (value.palettes) {
    out.palettes = { list: list<Re4PaletteScheme>(value.palettes.list, 'palettes.list').map(x => ({ ...x, used: Number(x.used) || 0, materials: Number(x.materials) || 0 })),
      active: list<string>(value.palettes.active, 'palettes.active'),
      selected: typeof value.palettes.selected === 'string' ? value.palettes.selected : '' };
  }
  if (value.presets) {
    out.presets = { ...value.presets, dismissed: value.presets.dismissed === true,
      list: list<Re4PresetEntry>(value.presets.list, 'presets.list'),
      better: list(value.presets.better, 'presets.better'), autosaves: list(value.presets.autosaves, 'presets.autosaves') };
  }
  return out;
}
