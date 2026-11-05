<script setup lang="ts">
import { computed, shallowRef, watch } from 'vue';
import { ElButton, ElInput, ElOption, ElRadio, ElRadioGroup, ElSelect } from '@reff/ui';
import type { Re4Translate } from './i18n';
import type { Re4ConditionDef, Re4Op } from './types';

// 加条件的表单。值的形式跟着条件类型走：布尔给是 / 否，枚举给档位名（存的是枚举值，
// 但没人应该去背"残血 = 2"），数值给比较符和数字。已有条件时才问「关系」——
// 它是整条规则共用的一个，加条件时一并改。
const props = defineProps<{ defs: Re4ConditionDef[]; existing: number; logic: 'AND' | 'OR'; busy: boolean; t: Re4Translate }>();
const emit = defineEmits<{ add: [condition: { type: string; op?: Re4Op; value: number | string | boolean }, logic: 'AND' | 'OR']; cancel: [] }>();
const type = shallowRef(props.defs[0]?.id ?? '');
const def = computed(() => props.defs.find(item => item.id === type.value));
const op = shallowRef<Re4Op>('<=');
const boolValue = shallowRef(true);
const enumValue = shallowRef<number | string>('');
const numValue = shallowRef('');
const logic = shallowRef<'AND' | 'OR'>(props.logic);
const invalid = shallowRef(false);
watch(def, value => {
  op.value = value?.ops?.[0] ?? '<=';
  enumValue.value = value?.options?.[0]?.value ?? '';
  invalid.value = false;
}, { immediate: true });

function current(item: Re4ConditionDef) {
  if (item.value === undefined) return '';
  if (typeof item.value === 'boolean') return ` (${props.t('currentValue')}: ${props.t(item.value ? 'yes' : 'no')})`;
  if (item.kind === 'enum') return ` (${props.t('currentValue')}: ${item.options?.find(o => o.value === item.value)?.label ?? item.value})`;
  return ` (${props.t('currentValue')}: ${Number(item.value).toFixed(1)})`;
}

function submit() {
  const selected = def.value;
  if (!selected) return;
  if (selected.kind === 'bool') return emit('add', { type: selected.id, value: boolValue.value }, logic.value);
  if (selected.kind === 'enum') return emit('add', { type: selected.id, op: op.value, value: enumValue.value }, logic.value);
  const number = Number(numValue.value);
  invalid.value = numValue.value.trim() === '' || !Number.isFinite(number);
  if (!invalid.value) emit('add', { type: selected.id, op: op.value, value: number }, logic.value);
}
</script>

<template>
  <div class="re4-condition-form">
    <div v-if="existing > 0" class="re4-row">
      <span class="re4-row-label">{{ t('logic') }}</span>
      <ElRadioGroup v-model="logic" :disabled="busy">
        <ElRadio value="AND">{{ t('logicAll') }}</ElRadio>
        <ElRadio value="OR">{{ t('logicAny') }}</ElRadio>
      </ElRadioGroup>
    </div>
    <div class="re4-row">
      <span class="re4-row-label">{{ t('conditionType') }}</span>
      <ElSelect v-model="type" filterable :disabled="busy" :aria-label="t('conditionType')" class="re4-condition-type">
        <ElOption v-for="item in defs" :key="item.id" :value="item.id" :label="item.label + current(item)" />
      </ElSelect>
    </div>
    <div v-if="def" class="re4-row">
      <span class="re4-row-label">{{ t('conditionValue') }}</span>
      <div class="re4-row-control">
        <ElRadioGroup v-if="def.kind === 'bool'" v-model="boolValue" :disabled="busy">
          <ElRadio :value="true">{{ t('yes') }}</ElRadio>
          <ElRadio :value="false">{{ t('no') }}</ElRadio>
        </ElRadioGroup>
        <template v-else>
          <ElSelect v-model="op" :disabled="busy" class="re4-op" :aria-label="t('conditionOp')">
            <ElOption v-for="item in def.ops ?? []" :key="item" :value="item" :label="item" />
          </ElSelect>
          <ElSelect v-if="def.kind === 'enum'" v-model="enumValue" :disabled="busy" :aria-label="t('conditionValue')">
            <ElOption v-for="item in def.options ?? []" :key="String(item.value)" :value="item.value" :label="item.label" />
          </ElSelect>
          <ElInput v-else v-model="numValue" :disabled="busy" class="re4-number" inputmode="decimal" :aria-label="t('conditionValue')" :aria-invalid="invalid" @keydown.enter="submit" />
        </template>
        <span v-if="invalid" class="re4-invalid" role="alert">{{ t('invalidValue') }}</span>
      </div>
    </div>
    <div class="re4-row">
      <span></span>
      <div class="re4-row-control">
        <ElButton type="primary" :disabled="busy || !def" @click="submit">{{ t('add') }}</ElButton>
        <ElButton :disabled="busy" @click="emit('cancel')">{{ t('cancel') }}</ElButton>
      </div>
    </div>
  </div>
</template>

<style>
.re4-condition-form { padding: 6px 10px; margin: 6px 0; border: 1px solid var(--avm-line); background: var(--avm-panel); }
.avm .re4-condition-type.el-select { width: min(24em, 100%); }
.avm .re4-op.el-select { width: 5.5em; }
.avm .re4-number.el-input { width: 8em; }
.re4-invalid { color: var(--el-color-danger, #f56c6c); font-size: var(--reff-font-size-xs, 12px); }
</style>
