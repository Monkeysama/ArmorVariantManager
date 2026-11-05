<script setup lang="ts">
import { computed } from 'vue';
import type { Re4Translate } from './i18n';
import type { Re4Snapshot } from './types';
import { shortSlot } from './util';

// 左侧常驻：游戏状态只读（HP + 当前成立的条件；详情在条件状态展开时看），
// 最终材质只在整套造型 / 状态组 / 条件状态页显示（快速切换用不到）。
const props = defineProps<{ snapshot: Re4Snapshot; t: Re4Translate; showLook: boolean }>();
const hp = computed(() => props.snapshot.status?.hp);
const notes = computed(() => {
  const out: Record<string, string> = {};
  for (const slot of props.snapshot.slots ?? []) for (const m of slot.materials) if (m.note) out[`${slot.id}/${m.name}`] = m.note;
  return out;
});
const slotLabel = (id: string) => shortSlot(props.snapshot.slots?.find(s => s.id === id)?.label ?? id);
const groupedLook = computed(() => {
  const out: { slot: string; rows: { material: string; on: boolean; note?: string }[] }[] = [];
  for (const row of props.snapshot.look ?? []) {
    let g = out.find(x => x.slot === row.slot);
    if (!g) { g = { slot: row.slot, rows: [] }; out.push(g); }
    g.rows.push({ material: row.material, on: row.on, note: notes.value[`${row.slot}/${row.material}`] });
  }
  return out;
});
const locating = computed(() => props.snapshot.locating);
</script>

<template>
  <aside class="re4-side">
    <section class="re4-panel re4-panel-body" :aria-label="t('gameState')">
      <p class="re4-eyebrow">{{ t('gameState') }}</p>
      <div v-if="hp !== undefined" class="re4-hp">
        <span>{{ t('hp') }}</span><span class="re4-hpbar" :class="{ low: hp <= 30 }"><i :style="{ width: Math.max(0, Math.min(100, hp)) + '%' }"></i></span>
        <span class="re4-hpnum">{{ hp.toFixed(1) }}%</span>
      </div>
      <div class="re4-chips">
        <span v-for="flag in snapshot.status?.flags ?? []" :key="flag" class="re4-chip on">{{ flag }}</span>
        <span v-if="!(snapshot.status?.flags ?? []).length" class="re4-muted re4-small">{{ t('noTrue') }}</span>
      </div>
    </section>
    <section v-if="showLook" class="re4-panel re4-panel-body" :aria-label="t('finalMaterials')">
      <p class="re4-eyebrow">{{ t('finalMaterials') }}</p>
      <p v-if="locating" class="re4-small" style="margin:0;color:var(--avm-accent)">{{ t('locatingNow', locating.material) }}</p>
      <div v-for="g in groupedLook" :key="g.slot" class="re4-look">
        <span class="re4-muted re4-small">{{ slotLabel(g.slot) }}</span>
        <div v-for="row in g.rows" :key="row.material" class="re4-look-row" :class="{ off: !row.on }">
          <span class="re4-ldot" :aria-label="row.on ? t('on') : t('off')"></span>
          <span class="re4-mono">{{ row.material }}</span><span v-if="row.note" class="re4-muted re4-small">{{ row.note }}</span>
        </div>
      </div>
    </section>
  </aside>
</template>

<style>
.re4-side { display: grid; gap: 10px; align-content: start; position: sticky; top: 8px; }
@media (max-width: 720px) { .re4-side { position: static; } }
.re4-hp { display: grid; grid-template-columns: auto minmax(0, 1fr) auto; gap: 8px; align-items: center; }
.re4-hpbar { height: 6px; border-radius: 3px; background: var(--re4-soft); overflow: hidden; }
.re4-hpbar i { display: block; height: 100%; background: var(--re4-ok); }
.re4-hpbar.low i { background: var(--re4-bad); }
.re4-hpnum { font-variant-numeric: tabular-nums; }
.re4-chips { display: flex; flex-wrap: wrap; gap: 4px; }
.re4-chip { font-size: 12px; padding: 0 7px; border-radius: 10px; border: 1px solid var(--avm-line); color: var(--avm-muted); }
.re4-chip.on { border-color: var(--re4-ok); background: var(--re4-ok-soft); color: var(--re4-ok); }
.re4-look { display: grid; gap: 1px; margin-top: 4px; }
.re4-look-row { display: flex; align-items: baseline; gap: 6px; min-width: 0; overflow-wrap: anywhere; }
.re4-ldot { width: 8px; height: 8px; border-radius: 50%; background: var(--avm-ink); flex: none; }
.re4-look-row.off .re4-ldot { background: transparent; border: 1.5px solid var(--avm-muted); }
.re4-look-row.off .re4-mono { color: var(--avm-muted); text-decoration: line-through; }
</style>
