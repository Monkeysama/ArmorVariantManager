<script setup lang="ts">
import { shallowRef, watch } from 'vue';
import { ElButton, ElOption, ElSelect } from '@reff/ui';
import type { Translate } from './i18n';

const props = defineProps<{ value: string | number; label: string; options: { value: string | number; label: string }[]; disabled: boolean; save: (value: string | number) => Promise<boolean>; t: Translate }>();
const draft = shallowRef(props.value);
const dirty = shallowRef(false);
watch(() => props.value, value => { if (!dirty.value) draft.value = value; });
async function commit(value = draft.value) {
  draft.value = value; dirty.value = true;
  if (await props.save(value)) { dirty.value = false; draft.value = props.value; }
}
</script>

<template>
  <label class="condition-select"><span class="field-label">{{ label }}</span>
    <div class="number-input-line"><ElSelect :model-value="draft" :disabled="disabled" :empty-values="[null, undefined]" :teleported="false" :aria-label="label" @change="commit"><ElOption v-for="option in options" :key="option.value" :value="option.value" :label="option.label" /></ElSelect><ElButton v-if="dirty" :disabled="disabled" @click="commit()">{{ t('applyValue') }}</ElButton></div>
  </label>
</template>
