<script setup lang="ts">
import { computed } from 'vue';
import { ElCheckbox, ElOption, ElSelect, ElSwitch } from '@reff/ui';
import type { Re4Translate } from './i18n';
import type { Re4Layer, Re4Perform, Re4Snapshot } from './types';

// 快速切换：日常最常用的入口，不出现材质 / 槛位字样。规则与 REF 面板一致：
//   * 整套造型永远给下拉框；挂了规则时旁边给「自动」，规则接管时标出来
//   * 基础状态组（无规则）手动拨：只有一个状态时就是勾选框，多个状态用下拉框
//   * 高级状态组（有规则）先看「自动」：开着时由条件决定、不给手动控件；关掉才能手动选
const props = defineProps<{ snapshot: Re4Snapshot; busy: boolean; perform: Re4Perform; t: Re4Translate }>();
const base = computed(() => props.snapshot.base!);
const axes = computed(() => props.snapshot.axes ?? []);
const basic = computed(() => axes.value.filter(layer => !layer.advanced));
const advanced = computed(() => axes.value.filter(layer => layer.advanced));
const paused = computed(() => [
  ...(base.value.rules.length > 0 && !base.value.auto ? [props.t('baseLayer')] : []),
  ...advanced.value.filter(layer => !layer.auto).map(layer => layer.name),
]);
const activeNames = (layers: Re4Layer[]) => layers.filter(layer => layer.effective).map(layer => layer.name);

function target(layer: Re4Layer) {
  return layer.base ? { character: props.snapshot.character } : { character: props.snapshot.character, axis: layer.name };
}
const select = (layer: Re4Layer, preset: unknown) => props.perform({ kind: 'active', ...target(layer), preset: String(preset ?? '') });
const setAuto = (layer: Re4Layer, enabled: unknown) => props.perform({ kind: 'auto', ...target(layer), enabled: enabled === true });
</script>

<template>
  <div class="re4-quick">
    <section class="re4-section">
      <div class="re4-row">
        <span class="re4-row-label">{{ t('baseLayer') }}</span>
        <div class="re4-row-control">
          <span v-if="base.presets.length === 0" class="re4-muted">{{ t('noPresets') }}</span>
          <template v-else>
            <ElSelect :model-value="base.active" :disabled="busy" :aria-label="t('baseLayer')" @change="value => select(base, value)">
              <ElOption value="" :label="t('none')" />
              <ElOption v-for="name in base.presets" :key="name" :value="name" :label="name" />
            </ElSelect>
            <ElSwitch v-if="base.rules.length > 0" :model-value="base.auto" :disabled="busy" :active-text="t('auto')" @change="value => setAuto(base, value)" />
            <span v-if="base.fromRule" class="avm-tag el-tag el-tag--small"><span class="el-tag__content">{{ t('byRule') }}: {{ base.effective }}</span></span>
          </template>
        </div>
      </div>
    </section>

    <section class="re4-section">
      <h2 class="re4-section-title">{{ t('basicAxes') }} <small>{{ t('basicAxesHint') }} · {{ activeNames(basic).join(', ') || t('none') }}</small></h2>
      <p v-if="axes.length === 0" class="re4-muted">{{ t('noAxes') }}</p>
      <div v-for="layer in basic" :key="layer.name" class="re4-row">
        <span class="re4-row-label">{{ layer.name }}</span>
        <div class="re4-row-control">
          <span v-if="layer.presets.length === 0" class="re4-muted">{{ t('noStates') }}</span>
          <ElCheckbox v-else-if="layer.presets.length === 1" :model-value="layer.active === layer.presets[0]" :disabled="busy"
            @change="value => select(layer, value === true ? layer.presets[0] : '')">{{ layer.presets[0] }}</ElCheckbox>
          <ElSelect v-else :model-value="layer.active" :disabled="busy" :aria-label="layer.name" @change="value => select(layer, value)">
            <ElOption value="" :label="t('none')" />
            <ElOption v-for="name in layer.presets" :key="name" :value="name" :label="name" />
          </ElSelect>
        </div>
      </div>
    </section>

    <section v-if="advanced.length > 0" class="re4-section">
      <h2 class="re4-section-title">{{ t('advancedAxes') }} <small>{{ t('advancedAxesHint') }} · {{ activeNames(advanced).join(', ') || t('none') }}</small></h2>
      <div v-for="layer in advanced" :key="layer.name" class="re4-row">
        <span class="re4-row-label">{{ layer.name }}</span>
        <div class="re4-row-control">
          <ElSwitch :model-value="layer.auto" :disabled="busy" :active-text="t('auto')" @change="value => setAuto(layer, value)" />
          <span v-if="layer.auto" :class="layer.fromRule ? 'avm-tag el-tag el-tag--small' : 're4-muted'">
            <span class="el-tag__content">{{ layer.fromRule ? t('byRule') : t('current') }}: {{ layer.effective || t('none') }}</span>
          </span>
          <ElSelect v-else :model-value="layer.active" :disabled="busy" :aria-label="layer.name" @change="value => select(layer, value)">
            <ElOption value="" :label="t('none')" />
            <ElOption v-for="name in layer.presets" :key="name" :value="name" :label="name" />
          </ElSelect>
        </div>
      </div>
    </section>

    <section class="re4-section">
      <p v-if="paused.length > 0" class="re4-note re4-paused">{{ t('autoPaused') }}: {{ paused.join(', ') }}</p>
      <p class="re4-note">{{ t('editInRef') }}</p>
    </section>
  </div>
</template>

<style>
.re4-paused { color: var(--el-color-warning, #e6a23c); }
</style>
