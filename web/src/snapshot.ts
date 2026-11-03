import type { Material, Part, Snapshot } from './types';

function list<T>(value: unknown, field: string): T[] {
  if (Array.isArray(value)) return value;
  // REFramework serializes an empty Lua table as null; some codecs use {}.
  if (value === null || (typeof value === 'object' && value && Object.keys(value).length === 0)) return [];
  throw new Error(`Invalid snapshot: ${field} must be an array`);
}
export function normalizeSnapshot(value: Snapshot): Snapshot {
  return {
    ...value,
    groups: list(value.groups, 'groups'),
    presets: list(value.presets, 'presets'),
    parts: list<Part>(value.parts, 'parts').map(part => ({
      ...part,
      materials: list<Material>(part.materials, 'materials').map(material => ({ ...material, groups: list(material.groups, 'material.groups') })),
    })),
    pending: Object.fromEntries(Object.entries(value.pending ?? {}).map(([part, materials]) => [part, materials ?? {}])),
  };
}
