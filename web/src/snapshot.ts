import type { ConditionDefinition, ConditionField, ConditionNode, ConditionRule, Conditions, ConditionTarget, Documentation, DocumentationEntry, DocumentationSection, Imports, Material, Part, SettingField, Settings, SettingsSection, Snapshot } from './types';

function list<T>(value: unknown, field: string): T[] {
  if (Array.isArray(value)) return value;
  // REFramework serializes an empty Lua table as null; some codecs use {}.
  if (value === null || (typeof value === 'object' && value && Object.keys(value).length === 0)) return [];
  throw new Error(`Invalid snapshot: ${field} must be an array`);
}
export function normalizeSnapshot(value: Snapshot): Snapshot {
  return {
    ...value,
    backupPending: value.backupPending ?? false,
    canImport: value.canImport ?? false,
    conditions: value.conditions ? normalizeConditions(value.conditions) : null,
    ...(value.settings !== undefined ? { settings: normalizeSettings(value.settings) } : {}),
    groups: list(value.groups, 'groups'),
    presets: list(value.presets, 'presets'),
    parts: list<Part>(value.parts, 'parts').map(part => ({
      ...part,
      materials: list<Material>(part.materials, 'materials').map(material => ({ ...material, groups: list(material.groups, 'material.groups') })),
    })),
    pending: Object.fromEntries(Object.entries(value.pending ?? {}).map(([part, materials]) => [part, materials ?? {}])),
  };
}

export function normalizeImports(value: Imports): Imports {
  return { ...value, files: list(value.files, 'imports.files') };
}

export function normalizeDocumentation(value: Documentation): Documentation {
  return { sections: list<DocumentationSection>(value.sections, 'documentation.sections').map(section => ({
    ...section,
    entries: list<DocumentationEntry>(section.entries, 'documentation.entries').map(entry => ({
      ...entry, paragraphs: list<string>(entry.paragraphs, 'documentation.paragraphs'),
    })),
  })) };
}

function normalizeSettings(value: Settings): Settings {
  return { ...value, sections: list<SettingsSection>(value?.sections ?? null, 'settings.sections').map(section => ({
    ...section,
    fields: list<SettingField>(section.fields, 'settings.fields').map(field => ({ ...field,
      ...(field.type === 'select' ? { options: list(field.options, 'settings.options') } : {}),
    })),
  })) };
}

function normalizeConditions(value: Conditions): Conditions {
  const targets = (value: unknown) => list<ConditionTarget>(value, 'condition.targets');
  return {
    ...value,
    targets: list<Conditions['targets'][number]>(value.targets, 'conditions.targets').map(group => ({ ...group, presets: list(group.presets, 'condition.presets') })),
    definitions: list<ConditionDefinition>(value.definitions, 'conditions.definitions').map(definition => ({
      ...definition,
      fields: list<ConditionField>(definition.fields, 'condition.fields').map(field => ({ ...field,
        ...(field.kind === 'select' ? { options: list(field.options, 'condition.options') } : {}),
        ...(field.modes !== undefined ? { modes: list(field.modes, 'condition.modes') } : {}),
      })),
      rules: list<ConditionRule>(definition.rules, 'condition.rules').map(rule => ({ ...rule,
        targets: targets(rule.targets),
        ...(rule.chain_nodes !== undefined ? { chain_nodes: list<ConditionNode>(rule.chain_nodes, 'condition.chain_nodes').map(node => ({ ...node, targets: targets(node.targets) })) } : {}),
      })),
    })),
  };
}
