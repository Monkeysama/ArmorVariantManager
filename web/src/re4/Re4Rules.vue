<script setup lang="ts">
import { computed, shallowRef, watch } from 'vue';
import { ElButton, ElCheckbox, ElInputNumber, ElOption, ElRadio, ElRadioGroup, ElSelect, ElSwitch } from '@reff/ui';
import Re4ConditionForm from './Re4ConditionForm.vue';
import type { Re4Translate } from './i18n';
import type { Re4Condition, Re4Layer, Re4Op, Re4Perform, Re4Rule, Re4Snapshot } from './types';

// 条件规则。左边选层（整套造型 / 各状态组），右边先看这一层全部规则的优先级概览，
// 再编辑某一个状态的规则。「命中」和「生效」分开标：优先级低的规则条件成立时确实命中了，
// 但被上面的压着，只标命中会让人以为坏了。
const props = defineProps<{ snapshot: Re4Snapshot; busy: boolean; perform: Re4Perform; t: Re4Translate }>();
const layers = computed(() => [props.snapshot.base!, ...(props.snapshot.axes ?? [])]);
const layerKey = shallowRef('');               // '' = 整套造型
const layer = computed(() => layers.value.find(item => (item.base ? '' : item.name) === layerKey.value) ?? layers.value[0]);
const state = shallowRef('');
const adding = shallowRef(false);
watch(layer, value => {
  if (!value.presets.includes(state.value)) state.value = value.presets[0] ?? '';
}, { immediate: true });
watch([layerKey, state], () => { adding.value = false; });
const rule = computed(() => layer.value.rules.find(item => item.preset === state.value && !item.orphan));

function target(extra: { preset: string }) {
  const value = layer.value;
  return { character: props.snapshot.character, ...(value.base ? {} : { axis: value.name }), ...extra };
}
function conditionText(condition: Re4Condition) {
  const label = condition.known ? condition.label : `${props.t('unknownCondition')} (${condition.type})`;
  if (typeof condition.value === 'boolean') return `${label} = ${props.t(condition.value ? 'yes' : 'no')}`;
  return `${label} ${condition.op ?? ''} ${condition.valueLabel ?? condition.value}`;
}
function ruleText(item: Re4Rule) {
  if (item.hpDrive.enabled) return props.t('hpDriveRule', item.hpDrive.upper, item.hpDrive.lower);
  if (item.conditions.length === 0) return props.t('noConditions');
  return item.conditions.map(conditionText).join(` ${props.t(item.logic === 'OR' ? 'or' : 'and')} `);
}
const ruleCount = (item: Re4Layer) => item.rules.length;

async function addCondition(condition: { type: string; op?: Re4Op; value: number | string | boolean }, logic: 'AND' | 'OR') {
  if (await props.perform({ kind: 'condition-add', ...target({ preset: state.value }), condition, logic })) adding.value = false;
}
const number = (value: number | undefined | null) => typeof value === 'number' && Number.isFinite(value) ? value : undefined;
</script>

<template>
  <div class="re4-rules">
    <nav class="re4-layer-list" :aria-label="t('layers')">
      <button v-for="item in layers" :key="item.base ? '' : item.name" class="catalog-row"
        :aria-pressed="(item.base ? '' : item.name) === layerKey" @click="layerKey = item.base ? '' : item.name">
        <span class="row-name">{{ item.name }}</span>
        <span v-if="ruleCount(item) > 0" class="row-tag">{{ ruleCount(item) }}</span>
      </button>
    </nav>

    <div class="re4-rule-detail">
      <section class="re4-section">
        <h2 class="re4-section-title">{{ t('rulesByPriority') }}</h2>
        <p v-if="layer.rules.length === 0" class="re4-muted">{{ t('noRules') }}</p>
        <ol v-else class="re4-rule-list">
          <li v-for="item in layer.rules" :key="item.index" :class="{ 'is-orphan': item.orphan }">
            <span class="re4-priority">{{ item.priority ?? '–' }}</span>
            <button class="re4-rule-target" :disabled="item.orphan" @click="state = item.preset">{{ item.preset }}</button>
            <span class="re4-rule-text">{{ ruleText(item) }}</span>
            <span v-if="item.hold > 0" class="re4-muted">[{{ t('holdTag') }} {{ item.hold }}s]</span>
            <span v-if="item.orphan" class="avm-tag tag-global el-tag el-tag--small"><span class="el-tag__content">{{ t('orphan') }}</span></span>
            <span v-else-if="item.effective" class="avm-tag el-tag el-tag--small"><span class="el-tag__content">{{ t('effective') }}</span></span>
            <span v-else-if="item.hits" class="re4-muted">{{ t('shadowed') }}</span>
            <ElButton size="small" :disabled="busy" @click="perform({ kind: 'rule-delete', character: snapshot.character, ...(layer.base ? {} : { axis: layer.name }), rule: item.index })">{{ t('deleteRule') }}</ElButton>
          </li>
        </ol>
      </section>

      <section class="re4-section">
        <p v-if="layer.presets.length === 0" class="re4-muted">{{ t('needPreset') }}</p>
        <template v-else>
          <div class="re4-row">
            <span class="re4-row-label">{{ t('state') }}</span>
            <ElSelect v-model="state" :disabled="busy" :aria-label="t('state')">
              <ElOption v-for="name in layer.presets" :key="name" :value="name" :label="name" />
            </ElSelect>
          </div>

          <h3 class="re4-subtitle">{{ state }} {{ t('ruleFor') }}</h3>
          <p v-if="!rule || rule.conditions.length === 0" class="re4-muted">{{ t('noConditions') }}</p>
          <ul v-else class="re4-condition-list">
            <li v-for="(condition, index) in rule.conditions" :key="index">
              <span v-if="index > 0" class="re4-join">{{ t(rule.logic === 'OR' ? 'or' : 'and') }}</span>
              <span>{{ conditionText(condition) }}</span>
              <ElButton size="small" :disabled="busy" :aria-label="t('deleteCondition')"
                @click="perform({ kind: 'condition-delete', ...target({ preset: state }), index: index + 1 })">×</ElButton>
            </li>
          </ul>
          <Re4ConditionForm v-if="adding" :defs="snapshot.conditions ?? []" :existing="rule?.conditions.length ?? 0"
            :logic="rule?.logic ?? 'AND'" :busy="busy" :t="t" @add="addCondition" @cancel="adding = false" />
          <ElButton v-else :disabled="busy" @click="adding = true">{{ t('addCondition') }}</ElButton>

          <template v-if="rule">
            <div class="re4-row">
              <span class="re4-row-label">{{ t('hold') }}</span>
              <ElInputNumber :model-value="rule.hold" :min="0" :max="600" :step="0.5" :precision="1" :disabled="busy"
                @change="value => number(value) !== undefined && perform({ kind: 'hold', ...target({ preset: state }), value: number(value)! })" />
            </div>
            <p class="re4-note">{{ t('holdHint') }}</p>
          </template>
        </template>
      </section>

      <section v-if="layer.presets.length > 0 && state" class="re4-section">
        <template v-if="rule">
          <div class="re4-row">
            <span class="re4-row-label">{{ t('dissolve') }}</span>
            <ElSwitch :model-value="rule.dissolve.enabled" :disabled="busy" @change="value => perform({ kind: 'dissolve', ...target({ preset: state }), enabled: value === true })" />
          </div>
          <template v-if="rule.dissolve.enabled && !rule.hpDrive.enabled">
            <div v-for="field in (['dissolve_hide_time', 'dissolve_show_time'] as const)" :key="field" class="re4-row">
              <span class="re4-row-label">{{ t(field === 'dissolve_hide_time' ? 'hideTime' : 'showTime') }}</span>
              <ElInputNumber :model-value="field === 'dissolve_hide_time' ? rule.dissolve.hideTime : rule.dissolve.showTime" :min="0" :max="10" :step="0.1" :precision="1" :disabled="busy"
                @change="value => number(value) !== undefined && perform({ kind: 'dissolve-time', ...target({ preset: state }), field, value: number(value)! })" />
            </div>
          </template>
        </template>
        <div class="re4-row">
          <span class="re4-row-label">{{ t('hpDrive') }}</span>
          <ElCheckbox :model-value="rule?.hpDrive.enabled ?? false" :disabled="busy"
            @change="value => perform({ kind: 'hp-drive', ...target({ preset: state }), enabled: value === true })" />
        </div>
        <template v-if="rule?.hpDrive.enabled">
          <div v-for="field in (['dissolve_hp_upper', 'dissolve_hp_lower'] as const)" :key="field" class="re4-row">
            <span class="re4-row-label">{{ t(field === 'dissolve_hp_upper' ? 'hpUpper' : 'hpLower') }}</span>
            <ElInputNumber :model-value="field === 'dissolve_hp_upper' ? rule.hpDrive.upper : rule.hpDrive.lower" :min="0" :max="100" :step="1" :precision="0" :disabled="busy"
              @change="value => number(value) !== undefined && perform({ kind: 'hp-bound', ...target({ preset: state }), field, value: number(value)! })" />
          </div>
          <div class="re4-row">
            <span class="re4-row-label">{{ t('hpDirection') }}</span>
            <ElRadioGroup :model-value="rule.hpDrive.invert" :disabled="busy" @change="value => perform({ kind: 'hp-invert', ...target({ preset: state }), enabled: value === true })">
              <ElRadio :value="false">{{ t('hpLow') }}</ElRadio>
              <ElRadio :value="true">{{ t('hpHigh') }}</ElRadio>
            </ElRadioGroup>
          </div>
          <p class="re4-note">{{ t('hpHint') }}</p>
        </template>
        <p class="re4-note">{{ t('dissolveHint') }}</p>
      </section>
    </div>
  </div>
</template>

<style>
.re4-rules { display: grid; grid-template-columns: minmax(9em, 14em) minmax(0, 1fr); flex: 1; min-height: 0; padding: 6px 0 10px; }
.re4-layer-list { display: flex; flex-direction: column; gap: 1px; padding: 0 0 0 12px; border-right: 1px solid var(--avm-line); overflow: auto; }
.re4-rule-detail { min-width: 0; overflow: auto; }
.re4-rule-list, .re4-condition-list { list-style: none; margin: 0; padding: 0; }
.re4-rule-list li, .re4-condition-list li { display: flex; flex-wrap: wrap; align-items: center; gap: 4px 8px; padding: 4px 0; border-bottom: 1px solid var(--avm-line); }
.re4-rule-list li.is-orphan { opacity: .75; }
.re4-priority { min-width: 1.5em; color: var(--avm-muted); font-variant-numeric: tabular-nums; }
.re4-rule-target { padding: 0; color: var(--avm-accent); background: none; border: 0; text-decoration: underline dotted; }
.re4-rule-target:disabled { color: var(--avm-muted); text-decoration: none; }
.re4-rule-text { flex: 1 1 12em; min-width: 0; overflow-wrap: anywhere; }
.re4-subtitle { font-size: inherit; font-weight: 600; margin: 10px 0 4px; }
.re4-join { color: var(--avm-muted); font-size: var(--reff-font-size-xs, 12px); }
.re4-condition-list li > span:nth-child(2), .re4-condition-list li > span:first-child:not(.re4-join) { flex: 1; overflow-wrap: anywhere; }
@media (max-width: 640px) { .re4-rules { grid-template-columns: minmax(0, 1fr); } .re4-layer-list { border-right: 0; padding: 0 12px; } }
</style>
