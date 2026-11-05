<script setup lang="ts">
import { computed, shallowRef } from 'vue';
import { ElSwitch } from '@reff/ui';
import type { Re4Translate } from './i18n';
import type { Re4Perform, Re4Snapshot } from './types';
import { conditionSentence, kindText, targetSentence } from './util';

// 快速切换：一切从简。被条件状态接管的层锁定（只在这里锁，编辑页照常能改手动选择）。
const props = defineProps<{ snapshot: Re4Snapshot; busy: boolean; perform: Re4Perform; t: Re4Translate }>();
const c = () => ({ character: props.snapshot.character });
const states = computed(() => props.snapshot.states ?? []);
const groupsOpen = shallowRef(true);
const owner = (index?: number) => index ? states.value[index - 1]?.name ?? '' : '';
const pick = (layer: string, option: string) => props.perform({ kind: 'manual', ...c(), layer, option });
const rows = computed(() => (props.snapshot.groups ?? []).map(g => ({
  layer: g.name, label: g.name, active: g.active, effective: g.effective, locked: g.fromState, none: true,
  options: g.options.map(o => o.name),
})));
const base = computed(() => {
  const b = props.snapshot.base!;
  return { layer: 'base', label: props.t('tabBase'), active: b.active, effective: b.effective, locked: b.fromState, none: false,
    options: b.presets.map(p => p.name) };
});
</script>

<template>
  <div class="re4-main">
    <section class="re4-panel re4-panel-body">
      <div class="re4-qrow" :class="{ locked: base.locked }">
        <span class="re4-qname">{{ base.label }}</span>
        <span class="re4-seg" role="group" :aria-label="base.label">
          <button v-for="name in base.options" :key="name" :disabled="busy || !!base.locked"
            :aria-pressed="base.active === name" :class="{ eff: base.locked && base.effective === name }"
            :title="base.locked ? t('lockedBy', owner(base.locked)) : ''" @click="pick('base', name)">{{ name }}</button>
        </span>
      </div>
    </section>

    <section class="re4-panel">
      <div class="re4-panel-head">
        <button class="re4-caret" :aria-expanded="groupsOpen" @click="groupsOpen = !groupsOpen">{{ groupsOpen ? '▾' : '▸' }}</button>
        <span class="re4-panel-title">{{ t('tabGroups') }}</span><span class="re4-muted re4-small">{{ t('groupsHint') }}</span>
      </div>
      <div v-if="groupsOpen" class="re4-panel-body">
        <span v-if="!rows.length" class="re4-muted re4-small">{{ t('noGroups') }}</span>
        <div v-for="row in rows" :key="row.layer" class="re4-qrow" :class="{ locked: row.locked }">
          <span class="re4-qname">{{ row.label }}</span>
          <span class="re4-seg" role="group" :aria-label="row.label">
            <button :disabled="busy || !!row.locked" :aria-pressed="row.active === ''" :title="row.locked ? t('lockedBy', owner(row.locked)) : ''"
              @click="pick(row.layer, '')">{{ t('none') }}</button>
            <button v-for="name in row.options" :key="name" :disabled="busy || !!row.locked"
              :aria-pressed="row.active === name" :class="{ eff: row.locked && row.effective === name }"
              :title="row.locked ? t('lockedBy', owner(row.locked)) : ''" @click="pick(row.layer, name)">{{ name }}</button>
          </span>
        </div>
      </div>
    </section>

    <section class="re4-panel">
      <div class="re4-panel-head">
        <ElSwitch :model-value="snapshot.auto" :disabled="busy" size="small" :title="t('conditionSwitchHint')"
          @change="v => perform({ kind: 'auto', ...c(), enabled: v === true })" />
        <span class="re4-panel-title">{{ t('conditionSwitch') }}</span>
      </div>
      <div class="re4-panel-body re4-sflow">
        <span v-if="!states.length" class="re4-muted re4-small">{{ t('noStates') }}</span>
        <label v-for="(st, i) in states" :key="i" class="re4-schip" :class="'k-' + st.kind"
          :title="conditionSentence(st, t) + ' → ' + targetSentence(st, t)">
          <input type="checkbox" :checked="st.enabled" :disabled="busy"
            @change="e => perform({ kind: 'state-field', ...c(), index: i + 1, field: 'enabled', value: (e.target as HTMLInputElement).checked })">
          <span class="re4-sdot" :title="kindText(st, states, t)"></span>
          <span class="re4-sname">{{ st.name }}</span>
        </label>
      </div>
    </section>
  </div>
</template>

<style>
.re4-qrow { display: grid; grid-template-columns: minmax(5em, 8em) minmax(0, 1fr); gap: 6px 12px; align-items: center; padding: 3px 0; }
.re4-qrow + .re4-qrow { border-top: 1px solid var(--avm-line); padding-top: 6px; }
@media (max-width: 520px) { .re4-qrow { grid-template-columns: minmax(0, 1fr); } }
.re4-qname { font-weight: 500; overflow-wrap: anywhere; }
.re4-qrow.locked .re4-qname { color: var(--avm-muted); }
.re4-seg { display: flex; flex-wrap: wrap; gap: 4px; }
.re4-seg button { border: 1px solid var(--avm-line); background: transparent; border-radius: 6px; padding: 1px 10px; color: var(--avm-muted); cursor: pointer; position: relative; min-height: 26px; }
.re4-seg button:hover:not(:disabled) { border-color: var(--avm-accent); }
.re4-seg button[aria-pressed=true] { background: var(--el-color-primary-light-9, var(--re4-soft)); border-color: var(--avm-accent); color: var(--avm-accent); font-weight: 500; }
.re4-seg button:disabled { cursor: not-allowed; }
.re4-seg button:disabled:not(.eff) { opacity: .4; }
.re4-seg button.eff { box-shadow: 0 0 0 2px var(--re4-ok); color: var(--avm-ink); opacity: 1; }
.re4-sflow { display: flex; flex-wrap: wrap; gap: 6px; }
.re4-schip { display: inline-flex; align-items: center; gap: 6px; padding: 2px 10px 2px 6px; border: 1px solid var(--avm-line); border-radius: 14px; cursor: pointer; user-select: none; }
.re4-schip input { margin: 0; }
.re4-schip .re4-sname { font-weight: 500; }
</style>
