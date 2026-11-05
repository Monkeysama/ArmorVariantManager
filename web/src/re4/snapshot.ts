import type { Re4Character, Re4Condition, Re4ConditionDef, Re4Conflict, Re4Layer, Re4Material, Re4PresetValues, Re4Rule, Re4SaveSlot, Re4Slot, Re4Snapshot } from './types';

// REFramework 把空 Lua 表序列化成 null（有的编码器给 {}）；缺省字段按空处理。
function list<T>(value: unknown, field: string): T[] {
  if (Array.isArray(value)) return value;
  if (value === null || value === undefined || (typeof value === 'object' && Object.keys(value).length === 0)) return [];
  throw new Error(`Invalid RE4 snapshot: ${field} must be an array`);
}

function rule(value: Re4Rule): Re4Rule {
  return { ...value, conditions: list<Re4Condition>(value.conditions, 'rule.conditions') };
}

// 以名字为键的表（预设 -> 槛位 -> 材质）：空 Lua 表同样会变成 null。
function map<T>(value: Record<string, T> | null | undefined, fill: (item: T) => T): Record<string, T> {
  return Object.fromEntries(Object.entries(value ?? {}).map(([key, item]) => [key, fill(item)]));
}
const values = (value: Re4PresetValues | null) => map(value, slot => slot ?? {});

function layer(value: Re4Layer): Re4Layer {
  return { ...value, active: value.active ?? '', presets: list<string>(value.presets, 'layer.presets'),
    rules: list<Re4Rule>(value.rules, 'layer.rules').map(rule),
    values: map(value.values, values),
    ...(value.base ? { match: map(value.match, match => ({ ...match, skipped: list<string>(match?.skipped, 'match.skipped') })) } : {}) };
}

export function normalizeRe4(value: Re4Snapshot): Re4Snapshot {
  return {
    ...value,
    characters: list<Re4Character>(value.characters, 'characters').map(item => ({ ...item, targets: list<string>(item.targets, 'character.targets') })),
    character: value.character ?? '',
    ...(value.status ? { status: { ...value.status, flags: list<string>(value.status.flags, 'status.flags') } } : {}),
    ...(value.conditions !== undefined ? { conditions: list<Re4ConditionDef>(value.conditions, 'conditions').map(def => ({
      ...def,
      ...(def.ops !== undefined ? { ops: list(def.ops, 'condition.ops') } : {}),
      ...(def.options !== undefined ? { options: list(def.options, 'condition.options') } : {}),
    })) } : {}),
    ...(value.base ? { base: layer(value.base) } : {}),
    ...(value.axes !== undefined ? { axes: list<Re4Layer>(value.axes, 'axes').map(layer) } : {}),
    ...(value.editor ? { editor: { ...value.editor,
      slots: list<Re4Slot>(value.editor.slots, 'editor.slots').map(slot => ({ ...slot, materials: list<Re4Material>(slot.materials, 'slot.materials') })),
      conflicts: list<Re4Conflict>(value.editor.conflicts, 'editor.conflicts').map(item => ({ ...item, parts: list(item.parts, 'conflict.parts') })) } } : {}),
    ...(value.saves ? { saves: { ...value.saves, slots: list<Re4SaveSlot>(value.saves.slots, 'saves.slots') } } : {}),
  };
}
