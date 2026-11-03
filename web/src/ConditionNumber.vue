<script setup lang="ts">
import { computed, shallowRef, watch } from 'vue';
import { ElButton, ElInput, ElSlider } from '@reff/ui';
import type { Translate } from './i18n';

const props = defineProps<{ value: number; label: string; id: string; min?: number; max?: number; step?: number; sliderMax?: number; disabled: boolean; save: (value: number) => Promise<boolean>; t: Translate }>();
const draft = shallowRef(String(props.value));
const dirty = shallowRef(false);
const focused = shallowRef(false);
const saving = shallowRef(false);
const input = shallowRef<{ blur: () => void }>();
const invalid = computed(() => !draft.value.trim() || !Number.isFinite(Number(draft.value))
  || (props.min !== undefined && Number(draft.value) < props.min) || (props.max !== undefined && Number(draft.value) > props.max));
const hasSlider = computed(() => props.min !== undefined && (props.max !== undefined || props.sliderMax !== undefined));
// 快调范围不是存储上限；旧配置和精确输入的范围外数值仍可保留。
const sliderMaximum = computed(() => props.max ?? Math.max(props.sliderMax ?? props.value, props.value, invalid.value ? props.value : Number(draft.value)));
const sliderValue = computed(() => invalid.value ? props.value : Number(draft.value));
watch(() => props.value, value => { if (!dirty.value && !focused.value) draft.value = String(value); });
watch(() => props.disabled, disabled => { if (disabled) { input.value?.blur(); focused.value = false; } });
async function commit() {
  if (!dirty.value || invalid.value || props.disabled || saving.value) return;
  saving.value = true;
  try {
    if (await props.save(Number(draft.value))) { dirty.value = false; draft.value = String(props.value); }
  } finally { saving.value = false; }
}
function slide(value: number | number[]) {
  if (typeof value !== 'number') return;
  draft.value = String(value); dirty.value = value !== props.value;
}
</script>

<template>
  <div class="condition-number">
    <label :for="id" class="field-label">{{ label }}</label>
    <div class="number-input-line" :class="{ 'slider-input-line': hasSlider }">
      <ElSlider v-if="hasSlider" :model-value="sliderValue" :min="min" :max="sliderMaximum" :step="step ?? 1" :disabled="disabled" :aria-label="label" :show-tooltip="false"
        @update:model-value="slide" @change="commit" />
      <ElInput ref="input" :id="id" v-model="draft" inputmode="decimal" :disabled="disabled" :aria-invalid="dirty && invalid" :aria-describedby="dirty && invalid ? id + '-error' : undefined"
        @input="dirty = true" @focus="focused = true" @blur="focused = false; commit()" @keyup.enter="commit" />
      <ElButton v-if="dirty" :disabled="disabled || invalid" @click="commit">{{ t('applyValue') }}</ElButton>
    </div>
    <span v-if="dirty && invalid" :id="id + '-error'" class="field-error">{{ t('validNumber') }}{{ min !== undefined ? ' ≥ ' + min : '' }}{{ max !== undefined ? ' ≤ ' + max : '' }}</span>
  </div>
</template>
