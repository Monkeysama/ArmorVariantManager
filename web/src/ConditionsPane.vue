<script setup lang="ts">
import { computed, shallowRef, watch } from 'vue';
import { ElButton, ElCheckbox, ElInput, ElRadio, ElRadioGroup } from '@reff/ui';
import ConditionNumber from './ConditionNumber.vue';
import ConditionSelect from './ConditionSelect.vue';
import ConditionTargets from './ConditionTargets.vue';
import type { ConditionAction, ConditionField, Conditions, Perform } from './types';
import type { Translate } from './i18n';

const props = defineProps<{ conditions: Conditions | null; busy: boolean; perform: Perform; t: Translate }>();
const selectedId = shallowRef(props.conditions?.selected ?? '');
const ruleIndex = shallowRef(1);
const deletingRule = shallowRef(false);
const ruleRevision = shallowRef(0);
const nodeKeys = shallowRef<Record<number, number>>({});
let nodeRevision = 0;
const hpTest = shallowRef('50');
const validHpTest = computed(() => hpTest.value.trim() && Number.isFinite(Number(hpTest.value)) && Number(hpTest.value) >= 0 && Number(hpTest.value) <= 100);
const definition = computed(() => props.conditions?.definitions.find(item => item.id === selectedId.value));
const rule = computed(() => definition.value?.rules.find(item => item.index === ruleIndex.value));
const fields = computed(() => definition.value?.fields.filter(field => !field.modes || field.modes.includes(Number(rule.value?.mode))) ?? []);
const chained = computed(() => Number(rule.value?.mode) === 3 && rule.value?.chain_nodes !== undefined);
watch(() => props.conditions, conditions => {
  if (!conditions) return;
  if (!conditions.parallel || !conditions.definitions.some(item => item.id === selectedId.value)) selectedId.value = conditions.selected || conditions.definitions[0]?.id || '';
}, { immediate: true });
watch(definition, value => {
  if (!value?.rules.some(item => item.index === ruleIndex.value)) ruleIndex.value = value?.rules[0]?.index ?? 1;
});
watch(selectedId, () => { ruleIndex.value = definition.value?.rules[0]?.index ?? 1; deletingRule.value = false; });
watch(ruleIndex, () => { deletingRule.value = false; });
function action(op: ConditionAction['op'], extra: Partial<ConditionAction> = {}) {
  return props.perform({ kind: 'condition', op, condition: selectedId.value, rule: ruleIndex.value, ...extra });
}
async function selectCondition(id: string) {
  if (props.conditions?.parallel || await action('select', { value: id })) selectedId.value = id;
}
function fieldValue(field: ConditionField) {
  const value = rule.value?.[field.key];
  return typeof value === 'string' || typeof value === 'number' ? value : field.default;
}
async function addRule() {
  if (await action('rule_add')) { const rules = definition.value?.rules ?? []; ruleIndex.value = rules[rules.length - 1]?.index ?? 1; }
}
async function deleteRule() {
  if (await action('rule_delete')) { deletingRule.value = false; ruleRevision.value++; }
}
async function deleteNode(index: number) {
  if (await action('chain_delete', { node: index })) {
    const revision = ++nodeRevision;
    nodeKeys.value = Object.fromEntries((rule.value?.chain_nodes ?? []).map(node => [node.index, node.index >= index ? revision : nodeKeys.value[node.index] ?? 0]));
  }
}
</script>

<template>
  <section class="conditions-workspace" :aria-label="t('conditions')">
    <template v-if="conditions">
      <aside class="conditions-sidebar">
        <div class="pane-heading"><h2>{{ t('conditions') }}</h2><span class="count">{{ conditions.definitions.length }}</span></div>
        <ElCheckbox v-if="conditions.canEnable" :model-value="conditions.enabled" :disabled="busy" @change="value => action('enabled', { value: !!value })">{{ t('enableConditions') }}</ElCheckbox>
        <ElRadioGroup class="conditions-mode" :model-value="conditions.parallel" :disabled="busy" :aria-label="t('conditionMode')" @change="value => action('parallel', { value: !!value })">
          <ElRadio :value="false">{{ t('singleCondition') }}</ElRadio><ElRadio :value="true">{{ t('parallelConditions') }}</ElRadio>
        </ElRadioGroup>
        <div class="catalog-list condition-list">
          <div v-for="item in conditions.definitions" :key="item.id" class="condition-list-row">
            <ElCheckbox v-if="conditions.parallel" :model-value="item.enabled" :disabled="busy" :aria-label="t('enableCondition') + ' ' + item.label" @change="value => action('setting', { condition: item.id, field: 'enabled', value: !!value })" />
            <button class="catalog-row" :disabled="busy" :aria-pressed="selectedId === item.id" @click="selectCondition(item.id)"><span class="row-name">{{ item.label }}</span><span v-if="conditions.parallel" class="row-tag">{{ item.priority }}</span><span class="row-arrow" aria-hidden="true">›</span></button>
          </div>
        </div>
        <div v-if="definition && conditions.parallel" :key="definition.id" class="condition-priority">
          <ConditionNumber :id="'priority-' + definition.id" :value="definition.priority" :label="t('priority') + ' · ' + definition.label" :disabled="busy" :save="value => action('setting', { field: 'priority', value })" :t="t" />
          <p class="condition-note">{{ t('priorityHelp') }}</p>
        </div>
      </aside>
      <div v-if="definition" class="condition-detail">
        <header class="condition-heading"><h2>{{ definition.label }}</h2><span v-if="definition.stateLabel" class="condition-state">{{ definition.stateLabel }}</span></header>
        <p v-if="definition.warning" class="condition-warning" role="status">{{ definition.warning }}</p>
        <div class="rule-toolbar">
          <nav class="rule-tabs" :aria-label="t('rules')"><button v-for="item in definition.rules" :key="item.index" :disabled="busy" :aria-current="ruleIndex === item.index ? 'page' : undefined" @click="ruleIndex = item.index">{{ item.label }}{{ definition.canAdd ? ' ' + item.index : '' }}</button></nav>
          <ElButton v-if="definition.canAdd" :disabled="busy" @click="addRule">{{ t('addRule') }}</ElButton>
        </div>
        <div v-if="rule" :key="definition.id + '-' + rule.index + '-' + ruleRevision" class="condition-rule">
          <div v-if="fields.length" class="condition-fields">
            <template v-for="field in fields" :key="field.key">
              <ConditionNumber v-if="field.kind === 'number'" :id="'rule-' + definition.id + '-' + rule.index + '-' + field.key" :value="Number(fieldValue(field))" :label="field.label" :min="field.min" :max="field.max" :step="field.step" :slider-max="field.sliderMax" :disabled="busy" :save="value => action('rule_set', { field: field.key, value })" :t="t" />
              <ConditionSelect v-else :value="fieldValue(field)" :label="field.label" :options="field.options ?? []" :disabled="busy" :save="value => action('rule_set', { field: field.key, value })" :t="t" />
            </template>
          </div>
          <template v-if="chained">
            <div class="condition-section-heading"><h3>{{ t('chainNodes') }}</h3><ElButton :disabled="busy" @click="action('chain_add')">{{ t('addNode') }}</ElButton></div>
            <section v-for="node in rule.chain_nodes" :key="node.index + '-' + (nodeKeys[node.index] ?? 0)" class="chain-node" :aria-label="t('chainNode') + ' ' + node.index">
              <div class="chain-node-heading"><h4>{{ t('chainNode') }} {{ node.index }}</h4><ElButton class="quiet-danger" :disabled="busy" @click="deleteNode(node.index)">{{ t('removeNode') }}</ElButton></div>
              <ConditionNumber :id="'chain-' + definition.id + '-' + rule.index + '-' + node.index" :value="node.duration" :label="t('nodeDuration')" :min="0" :slider-max="60" :step="0.1" :disabled="busy" :save="value => action('chain_set', { node: node.index, field: 'duration', value })" :t="t" />
              <ConditionTargets :targets="node.targets" :groups="conditions.targets" :condition="definition.id" :rule="rule.index" :node="node.index" :disabled="busy" :perform="perform" :t="t" />
            </section>
            <p v-if="!rule.chain_nodes?.length" class="empty-note">{{ t('noNodes') }}</p>
          </template>
          <template v-else>
            <div class="condition-section-heading"><h3>{{ t('ruleTargets') }}</h3></div>
            <ConditionTargets :targets="rule.targets" :groups="conditions.targets" :condition="definition.id" :rule="rule.index" :disabled="busy" :perform="perform" :t="t" />
          </template>
          <div v-if="definition.canRemove" class="condition-rule-remove">
            <ElButton v-if="!deletingRule" class="quiet-danger" :disabled="busy" @click="deletingRule = true">{{ t('deleteRule') }}</ElButton>
            <div v-else class="delete-confirm" role="alert"><p>{{ t('confirmDelete') }} {{ rule.label }}？</p><div class="button-pair"><ElButton @click="deletingRule = false">{{ t('cancel') }}</ElButton><ElButton :disabled="busy" @click="deleteRule">{{ t('confirm') }}</ElButton></div></div>
          </div>
        </div>
        <p v-else class="empty-note">{{ t('noRules') }}</p>
        <section v-if="(conditions.canTestHp && definition.id === 'hp') || (conditions.canTestDamage && definition.id === 'damage')" class="condition-tests" :aria-label="t('conditionTest')">
          <h3>{{ t('conditionTest') }}</h3>
          <div v-if="conditions.canTestHp && definition.id === 'hp'" class="hp-test"><label for="condition-hp-test" class="field-label">{{ t('testHp') }}</label><ElInput id="condition-hp-test" v-model="hpTest" inputmode="decimal" :disabled="busy" /><ElButton :disabled="busy || !validHpTest" @click="action('test_hp', { value: Number(hpTest) })">{{ t('setHp') }}</ElButton></div>
          <ElButton v-if="conditions.canTestDamage && definition.id === 'damage'" :disabled="busy" @click="action('test_damage')">{{ t('testDamage') }}</ElButton>
        </section>
      </div>
      <p v-else class="empty-note">{{ t('noConditions') }}</p>
    </template>
    <p v-else class="empty-note">{{ t('wait') }}</p>
  </section>
</template>
