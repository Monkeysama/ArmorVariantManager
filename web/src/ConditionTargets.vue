<script setup lang="ts">
import { shallowRef } from 'vue';
import { ElButton } from '@reff/ui';
import ConditionSelect from './ConditionSelect.vue';
import type { ConditionAction, Conditions, ConditionTarget, Perform } from './types';
import type { Translate } from './i18n';

const props = defineProps<{ targets: ConditionTarget[]; groups: Conditions['targets']; condition: string; rule: number; node?: number; disabled: boolean; perform: Perform; t: Translate }>();
const targetKeys = shallowRef<Record<number, number>>({});
let targetRevision = 0;
function action(op: ConditionAction['op'], target?: number, field?: string, value?: string) {
  return props.perform({ kind: 'condition', op, condition: props.condition, rule: props.rule, node: props.node, target, field, value });
}
async function deleteTarget(index: number) {
  if (await action('target_delete', index)) {
    const revision = ++targetRevision;
    targetKeys.value = Object.fromEntries(props.targets.map(target => [target.index, target.index >= index ? revision : targetKeys.value[target.index] ?? 0]));
  }
}
function presets(target: ConditionTarget) { return props.groups.find(group => group.name === target.group)?.presets ?? []; }
function missingGroup(target: ConditionTarget) { return !props.groups.some(group => group.name === target.group); }
function groupOptions(target: ConditionTarget) {
  return [
    ...(missingGroup(target) ? [{ value: target.group, label: (target.group || props.t('main')) + ' · ' + props.t('missingTarget') }] : []),
    ...props.groups.map(group => ({ value: group.name, label: group.label + (group.global ? ' · ' + props.t('global') : '') })),
  ];
}
function presetOptions(target: ConditionTarget) {
  const names = presets(target);
  return [
    { value: '', label: props.t('choosePreset') },
    ...(target.preset && !names.includes(target.preset) ? [{ value: target.preset, label: target.preset + ' · ' + props.t('missingTarget') }] : []),
    ...names.map(name => ({ value: name, label: name })),
  ];
}
</script>

<template>
  <div class="condition-targets">
    <div v-for="target in targets" :key="target.index + '-' + (targetKeys[target.index] ?? 0)" class="condition-target-row">
      <div class="target-selects">
        <ConditionSelect :value="target.group" :label="t('targetGroup') + ' ' + target.index" :options="groupOptions(target)" :disabled="disabled" :save="value => action('target_set', target.index, 'group', String(value))" :t="t" />
        <ConditionSelect :key="target.group" :value="target.preset" :label="t('targetPreset') + ' ' + target.index" :options="presetOptions(target)" :disabled="disabled" :save="value => action('target_set', target.index, 'preset', String(value))" :t="t" />
      </div>
      <ElButton class="target-remove quiet-danger" :disabled="disabled" :aria-label="t('removeTarget') + ' ' + target.index" @click="deleteTarget(target.index)">{{ t('removeTarget') }}</ElButton>
    </div>
    <p v-if="!targets.length" class="target-empty">{{ t('noTargets') }}</p>
    <ElButton class="add-target" :disabled="disabled || !groups.length" @click="action('target_add')">{{ t('addTarget') }}</ElButton>
  </div>
</template>
