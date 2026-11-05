<script setup lang="ts">
import { computed, reactive, shallowRef } from 'vue';
import { ElButton, ElInput, ElSwitch } from '@reff/ui';
import type { Re4Translate } from './i18n';
import type { Re4Perform, Re4Snapshot, Re4Values } from './types';
import { keyOf, splitKey, usersOf } from './util';

// 整套造型 / 状态组的编辑页（两个页签共用）。可折叠的栏默认收起。
//   整套造型：完整快照，材质只有开 / 关；新建时抓当前外观。
//   状态组：先用「编辑范围」划定管哪些材质（一个材质只属于一个组），选项在范围里设「- / 关 / 开」。
const props = defineProps<{ mode: 'base' | 'groups'; snapshot: Re4Snapshot; busy: boolean; perform: Re4Perform; t: Re4Translate }>();
const c = () => ({ character: props.snapshot.character });

const open = reactive(new Set<string>());          // 展开的组 / 选项
const scopeOpen = reactive(new Set<string>());
const toggle = (set: Set<string>, key: string) => { if (set.has(key)) set.delete(key); else set.add(key); };
const notes = shallowRef(false);
const renaming = shallowRef<{ id: string; value: string } | null>(null);
const confirming = shallowRef('');
const newGroupName = shallowRef('');

// 当前模型的材质(镜像开着时不编辑护甲)
const slots = computed(() => (props.snapshot.slots ?? []).filter(s => !s.mirrored));
const allKeys = computed(() => slots.value.flatMap(s => s.materials.map(m => keyOf(s.id, m.name))));
const noteOf = computed(() => {
  const out: Record<string, string> = {};
  for (const s of props.snapshot.slots ?? []) for (const m of s.materials) if (m.note) out[keyOf(s.id, m.name)] = m.note;
  return out;
});
const owners = computed(() => {
  const out: Record<string, string> = {};
  for (const g of props.snapshot.groups ?? []) for (const k of g.scope) out[k] = g.name;
  return out;
});
const stateName = (i?: number) => i ? props.snapshot.states?.[i - 1]?.name ?? '' : '';

interface Card {
  id: string; isBase: boolean; name: string; active: string; effective?: string; fromState?: number;
  scope: string[]; options: { name: string; values: Re4Values; match?: { status: string; skipped: string[] } }[];
}
const cards = computed<Card[]>(() => {
  if (props.mode === 'base') {
    const b = props.snapshot.base!;
    return [{ id: 'base', isBase: true, name: props.t('tabBase'), active: b.active, effective: b.effective, fromState: b.fromState,
      scope: allKeys.value, options: b.presets }];
  }
  return (props.snapshot.groups ?? []).map(g => ({ id: 'g:' + g.name, isBase: false, name: g.name, active: g.active,
    effective: g.effective, fromState: g.fromState, scope: g.scope, options: g.options }));
});

const counts = (card: Card, values: Re4Values) => {
  let on = 0, off = 0;
  for (const k of card.scope) { if (values[k] === true) on++; else if (values[k] === false) off++; }
  return { on, off, ignore: card.scope.length - on - off };
};
const users = (card: Card, option?: string) => usersOf(props.snapshot, card.isBase ? null : card.name, option);

function act(kind: string, card: Card, extra: Record<string, unknown>) {
  const target = card.isBase ? {} : { group: card.name };
  return props.perform({ kind, ...c(), ...target, ...extra } as never);
}
const pick = (card: Card, option: string) => props.perform({ kind: 'manual', ...c(), layer: card.isBase ? 'base' : card.name, option });
const prefix = (card: Card) => card.isBase ? 'base' : 'option';

function setMaterial(card: Card, option: string, key: string, value: 'none' | 'off' | 'on') {
  const [slot, material] = splitKey(key);
  if (card.isBase) return props.perform({ kind: 'base-material', ...c(), preset: option, slot, material, value: value === 'on' });
  return props.perform({ kind: 'option-material', ...c(), group: card.name, option, slot, material, value });
}
const valueOf = (values: Re4Values, key: string) => values[key] === true ? 'on' : values[key] === false ? 'off' : 'none';

function startRename(id: string, value: string) { renaming.value = { id, value }; confirming.value = ''; }
async function commitRename(card: Card, option?: string) {
  const r = renaming.value;
  if (!r) return;
  const name = r.value.trim();
  renaming.value = null;
  if (!name) return;
  if (option === undefined) { if (name !== card.name) await props.perform({ kind: 'group-rename', ...c(), group: card.name, name }); return; }
  if (name === option) return;
  if (card.isBase) await props.perform({ kind: 'base-rename', ...c(), preset: option, name });
  else await props.perform({ kind: 'option-rename', ...c(), group: card.name, option, name });
}
async function remove(card: Card, option?: string) {
  confirming.value = '';
  if (option === undefined) await props.perform({ kind: 'group-delete', ...c(), group: card.name });
  else if (card.isBase) await props.perform({ kind: 'base-delete', ...c(), preset: option });
  else await props.perform({ kind: 'option-delete', ...c(), group: card.name, option });
}
async function newOption(card: Card) {
  if (await act('option-new', card, {})) open.add(card.id);
}
async function newGroup() {
  const name = newGroupName.value.trim();
  if (!name) return;
  if (await props.perform({ kind: 'group-new', ...c(), name })) { newGroupName.value = ''; open.add('g:' + name); scopeOpen.add('g:' + name); }
}
function scopeToggle(card: Card, key: string) {
  const [slot, material] = splitKey(key);
  const inside = card.scope.includes(key);
  return props.perform({ kind: inside ? 'scope-remove' : 'scope-add', ...c(), group: card.name, slot, material });
}
const setNote = (key: string, text: string) => { const [slot, material] = splitKey(key); return props.perform({ kind: 'note', ...c(), slot, material, text }); };
const locate = (key: string) => { const [slot, material] = splitKey(key); return props.perform({ kind: 'locate', ...c(), slot, material }); };
const slotLabel = (id: string) => props.snapshot.slots?.find(s => s.id === id)?.label ?? id;
</script>

<template>
  <div class="re4-main">
    <p class="re4-lead">{{ mode === 'base' ? t('baseLead') : t('groupsLead') }}</p>
    <div class="re4-row">
      <ElSwitch v-model="notes" size="small" /><span>{{ t('notesMode') }}</span><span class="re4-muted re4-small">{{ t('notesHint') }}</span>
    </div>
    <p v-if="(snapshot.slots ?? []).some(s => s.mirrored)" class="re4-muted re4-small" style="margin:0">{{ t('armorMirrored') }}</p>

    <section v-for="card in cards" :key="card.id" class="re4-panel">
      <div class="re4-panel-head">
        <button class="re4-caret" :aria-expanded="open.has(card.id)" @click="toggle(open, card.id)">{{ open.has(card.id) ? '▾' : '▸' }}</button>
        <template v-if="!card.isBase && renaming?.id === card.id">
          <ElInput v-model="renaming.value" size="small" style="width:10em" :aria-label="t('groupName')" @keyup.enter="commitRename(card)" />
          <ElButton size="small" type="primary" @click="commitRename(card)">{{ t('done') }}</ElButton>
          <ElButton size="small" @click="renaming = null">{{ t('cancel') }}</ElButton>
        </template>
        <span v-else class="re4-panel-title">{{ card.name }}</span>
        <span class="re4-muted re4-small">
          {{ card.isBase ? t('baseCount', card.options.length) : t('optionsCount', card.options.length) + ' · ' + t('materialsCount', card.scope.length) }}
          <template v-if="users(card).length"> · {{ t('usedByCount', users(card).length) }}</template>
        </span>
        <span v-if="!open.has(card.id)" class="re4-muted re4-small">{{ t('manualIs', card.active || t('none')) }}</span>
        <span v-if="card.fromState" class="re4-tag ok">{{ t('takenOverBy', stateName(card.fromState)) }}</span>
        <span class="re4-spacer"></span>
        <template v-if="card.isBase">
          <ElButton size="small" :disabled="busy" @click="perform({ kind: 'base-new', ...c() }).then(ok => ok && open.add(card.id))">{{ t('newBase') }}</ElButton>
        </template>
        <template v-else-if="renaming?.id !== card.id">
          <ElButton size="small" :disabled="busy" @click="toggle(scopeOpen, card.id); open.add(card.id)">{{ t('editScope') }}</ElButton>
          <ElButton size="small" :disabled="busy" @click="startRename(card.id, card.name)">{{ t('rename') }}</ElButton>
          <ElButton size="small" type="danger" plain :disabled="busy" @click="confirming = card.id">{{ t('delete') }}</ElButton>
        </template>
      </div>
      <div v-if="confirming === card.id" class="re4-confirm">
        <span>{{ t('delete') }}「{{ card.name }}」？<template v-if="users(card).length">{{ t('deleteWarnUsed', users(card).map(s => s.name).join('」「')) }}</template>{{ t('backupFirst') }}</span>
        <ElButton size="small" type="danger" @click="remove(card)">{{ t('confirmDelete') }}</ElButton><ElButton size="small" @click="confirming = ''">{{ t('cancel') }}</ElButton>
      </div>

      <template v-if="open.has(card.id)">
        <div v-if="scopeOpen.has(card.id)" class="re4-scope">
          <p class="re4-muted re4-small" style="margin:0">{{ t('scopeHint') }}</p>
          <div v-for="slot in slots" :key="slot.id" class="re4-scope-part">
            <span class="re4-muted re4-small">{{ slot.label }}</span>
            <template v-for="m in slot.materials" :key="m.name">
              <button v-if="owners[`${slot.id}/${m.name}`] && owners[`${slot.id}/${m.name}`] !== card.name" class="re4-mchip" disabled
                :title="t('ownedBy', owners[`${slot.id}/${m.name}`])">{{ m.name }} · {{ owners[`${slot.id}/${m.name}`] }}</button>
              <button v-else class="re4-mchip" :class="{ in: card.scope.includes(`${slot.id}/${m.name}`) }" :disabled="busy"
                :aria-pressed="card.scope.includes(`${slot.id}/${m.name}`)" @click="scopeToggle(card, `${slot.id}/${m.name}`)">
                {{ card.scope.includes(`${slot.id}/${m.name}`) ? '✓' : '+' }} {{ m.name }}</button>
            </template>
          </div>
          <div><ElButton size="small" type="primary" @click="scopeOpen.delete(card.id)">{{ t('done') }}</ElButton></div>
        </div>

        <div class="re4-olist">
          <div v-if="!card.isBase" class="re4-orow" :class="{ manual: card.active === '' }">
            <span class="re4-caret"></span>
            <label class="re4-oname"><input type="radio" :name="card.id" :checked="card.active === ''" :disabled="busy" @change="pick(card, '')">{{ t('none') }}</label>
            <span class="re4-muted re4-small">{{ t('noneOption') }}</span><span></span>
          </div>
          <template v-for="opt in card.options" :key="opt.name">
            <div class="re4-orow" :class="{ manual: card.active === opt.name, eff: card.fromState && card.effective === opt.name }">
              <button class="re4-caret" :aria-expanded="open.has(card.id + '|' + opt.name)" @click="toggle(open, card.id + '|' + opt.name)">{{ open.has(card.id + '|' + opt.name) ? '▾' : '▸' }}</button>
              <span v-if="renaming?.id === card.id + '|' + opt.name" class="re4-oname">
                <ElInput v-model="renaming.value" size="small" style="width:9em" @keyup.enter="commitRename(card, opt.name)" />
              </span>
              <label v-else class="re4-oname"><input type="radio" :name="card.id" :checked="card.active === opt.name" :disabled="busy" @change="pick(card, opt.name)">{{ opt.name }}</label>
              <span class="re4-oinfo">
                <button class="re4-sum" @click="toggle(open, card.id + '|' + opt.name)">
                  <span class="on">{{ t('countOn', counts(card, opt.values).on) }}</span><span>{{ t('countOff', counts(card, opt.values).off) }}</span>
                  <span v-if="!card.isBase && counts(card, opt.values).ignore" class="re4-muted">{{ t('countIgnore', counts(card, opt.values).ignore) }}</span>
                </button>
                <span v-if="opt.match?.status === 'mismatch'" class="re4-res broken">{{ t('mismatch') }}</span>
                <span v-else-if="opt.match?.status === 'partial'" class="re4-res broken">{{ t('partialSlots', opt.match.skipped.join('、')) }}</span>
                <span v-if="users(card, opt.name).length" class="re4-used">{{ t('usedBy') }}<b>{{ users(card, opt.name).map(s => s.name).join('、') }}</b></span>
              </span>
              <span class="re4-oact">
                <template v-if="renaming?.id === card.id + '|' + opt.name">
                  <ElButton size="small" type="primary" @click="commitRename(card, opt.name)">{{ t('done') }}</ElButton>
                  <ElButton size="small" @click="renaming = null">{{ t('cancel') }}</ElButton>
                </template>
                <template v-else>
                  <ElButton size="small" :disabled="busy" @click="startRename(card.id + '|' + opt.name, opt.name)">{{ t('rename') }}</ElButton>
                  <ElButton size="small" type="danger" plain :disabled="busy" @click="confirming = card.id + '|' + opt.name">{{ t('delete') }}</ElButton>
                </template>
              </span>
            </div>
            <div v-if="confirming === card.id + '|' + opt.name" class="re4-confirm">
              <span>{{ t('delete') }}「{{ opt.name }}」？<template v-if="users(card, opt.name).length">{{ t('deleteWarnUsed', users(card, opt.name).map(s => s.name).join('」「')) }}</template>{{ t('backupFirst') }}</span>
              <ElButton size="small" type="danger" @click="remove(card, opt.name)">{{ t('confirmDelete') }}</ElButton><ElButton size="small" @click="confirming = ''">{{ t('cancel') }}</ElButton>
            </div>
            <div v-if="open.has(card.id + '|' + opt.name)" class="re4-mlist-wrap">
              <div class="re4-row re4-mtools">
                <ElButton size="small" :disabled="busy" @click="act(prefix(card) + '-move', card, card.isBase ? { preset: opt.name, offset: -1 } : { option: opt.name, offset: -1 })">{{ t('moveUp') }}</ElButton>
                <ElButton size="small" :disabled="busy" @click="act(prefix(card) + '-move', card, card.isBase ? { preset: opt.name, offset: 1 } : { option: opt.name, offset: 1 })">{{ t('moveDown') }}</ElButton>
                <ElButton size="small" :disabled="busy" @click="act(prefix(card) + '-duplicate', card, card.isBase ? { preset: opt.name } : { option: opt.name })">{{ t('duplicate') }}</ElButton>
                <template v-if="card.isBase">
                  <ElButton v-if="confirming !== 'rc|' + opt.name" size="small" :disabled="busy" @click="confirming = 'rc|' + opt.name">{{ t('recapture') }}</ElButton>
                  <template v-else>
                    <ElButton size="small" type="danger" @click="confirming = ''; perform({ kind: 'base-recapture', ...c(), preset: opt.name })">{{ t('confirmRecapture') }}</ElButton>
                    <ElButton size="small" @click="confirming = ''">{{ t('cancel') }}</ElButton>
                  </template>
                </template>
              </div>
              <span v-if="!card.scope.length" class="re4-muted re4-small">{{ t('emptyScope') }}</span>
              <div class="re4-mlist" :class="{ notes }">
                <div v-for="key in card.scope" :key="key" class="re4-mrow">
                  <span class="re4-tri" role="group" :aria-label="key">
                    <button v-if="!card.isBase" :aria-pressed="valueOf(opt.values, key) === 'none'" :disabled="busy" class="t-none" :title="t('ignore')" @click="setMaterial(card, opt.name, key, 'none')">-</button>
                    <button :aria-pressed="valueOf(opt.values, key) === 'off'" :disabled="busy" class="t-off" @click="setMaterial(card, opt.name, key, 'off')">{{ t('off') }}</button>
                    <button :aria-pressed="valueOf(opt.values, key) === 'on'" :disabled="busy" class="t-on" @click="setMaterial(card, opt.name, key, 'on')">{{ t('on') }}</button>
                  </span>
                  <span class="re4-mono re4-mname" :class="valueOf(opt.values, key)" :title="slotLabel(splitKey(key)[0])">{{ splitKey(key)[1] }}</span>
                  <template v-if="notes">
                    <input class="re4-alias" :value="noteOf[key] ?? ''" :placeholder="t('notePlaceholder')" :aria-label="key"
                      @change="e => setNote(key, (e.target as HTMLInputElement).value)">
                    <ElButton size="small" :disabled="busy" @click="locate(key)">{{ t('locate') }}</ElButton>
                  </template>
                  <span v-else-if="noteOf[key]" class="re4-muted re4-small">{{ noteOf[key] }}</span>
                </div>
              </div>
            </div>
          </template>
        </div>
        <div v-if="!card.isBase" class="re4-panel-body" style="border-top:1px solid var(--avm-line)">
          <div><ElButton size="small" :disabled="busy" @click="newOption(card)">{{ t('newOption') }}</ElButton></div>
        </div>
      </template>
    </section>

    <div v-if="mode === 'groups'" class="re4-row">
      <ElInput v-model="newGroupName" size="small" style="width:12em" :placeholder="t('groupName')" @keyup.enter="newGroup" />
      <ElButton size="small" :disabled="busy || !newGroupName.trim()" @click="newGroup">{{ t('newGroup') }}</ElButton>
    </div>
  </div>
</template>

<style>
.re4-olist { display: grid; }
.re4-orow { display: grid; grid-template-columns: 1.4em minmax(0, 10em) minmax(0, 1fr) auto; gap: 4px 10px; align-items: center; min-height: 34px; padding: 3px 12px; }
.re4-olist > * + .re4-orow { border-top: 1px solid var(--avm-line); }
.re4-orow.manual { background: var(--re4-soft); }
.re4-orow.eff .re4-oname { color: var(--re4-ok); }
@media (max-width: 640px) { .re4-orow { grid-template-columns: 1.4em minmax(0, 1fr); } .re4-orow .re4-oinfo, .re4-orow .re4-oact { grid-column: 2; } }
.re4-oname { display: inline-flex; align-items: center; gap: 7px; cursor: pointer; font-weight: 500; overflow-wrap: anywhere; min-width: 0; }
.re4-oname input[type=radio] { margin: 0; }
.re4-oinfo { display: flex; flex-wrap: wrap; align-items: center; gap: 2px 10px; min-width: 0; font-size: 12.5px; color: var(--avm-muted); }
.re4-sum { border: 0; background: none; padding: 0; color: inherit; display: inline-flex; gap: 8px; cursor: pointer; font-size: inherit; }
.re4-sum .on { color: var(--re4-ok); }
.re4-used { color: var(--avm-accent); }
.re4-used b { font-weight: 500; }
.re4-oact { display: flex; gap: 4px; flex-wrap: wrap; justify-content: flex-end; }
.re4-oact .el-button + .el-button, .re4-mtools .el-button + .el-button { margin-left: 0; }
.re4-mlist-wrap { padding: 6px 12px 8px 3.2em; background: var(--re4-soft); border-top: 1px dashed var(--avm-line); display: grid; gap: 6px; }
@media (max-width: 640px) { .re4-mlist-wrap { padding-left: 12px; } }
.re4-mlist { display: grid; grid-template-columns: repeat(auto-fill, minmax(15em, 1fr)); gap: 2px 16px; }
.re4-mlist.notes { grid-template-columns: repeat(auto-fill, minmax(24em, 1fr)); }
.re4-mrow { display: flex; align-items: center; gap: 8px; min-height: 26px; min-width: 0; }
.re4-tri { display: inline-flex; border: 1px solid var(--avm-line); border-radius: 5px; overflow: hidden; flex: none; }
.re4-tri button { border: 0; background: transparent; width: 2.2em; height: 22px; padding: 0; font-size: 12px; color: var(--avm-muted); cursor: pointer; }
.re4-tri button + button { border-left: 1px solid var(--avm-line); }
.re4-tri button.t-none[aria-pressed=true] { background: var(--avm-line); color: var(--avm-ink); }
.re4-tri button.t-off[aria-pressed=true] { background: var(--avm-muted); color: var(--el-bg-color, #fff); }
.re4-tri button.t-on[aria-pressed=true] { background: var(--re4-ok); color: var(--el-bg-color, #fff); }
.re4-mname { overflow-wrap: anywhere; }
.re4-mname.none { color: var(--avm-muted); }
.re4-mname.off { color: var(--avm-muted); text-decoration: line-through; }
.re4-alias { width: 8em; border: 1px solid var(--avm-line); border-radius: 4px; background: transparent; color: inherit; padding: 0 5px; }
.re4-scope { padding: 8px 12px 10px; background: var(--re4-soft); border-top: 1px solid var(--avm-line); display: grid; gap: 6px; }
.re4-scope-part { display: flex; flex-wrap: wrap; align-items: center; gap: 4px 6px; }
.re4-scope-part > span { width: 5em; }
.re4-mchip { font-family: var(--reff-font-mono, ui-monospace, Consolas, monospace); font-size: 11.5px; padding: 1px 7px; border-radius: 4px; border: 1px dashed var(--avm-muted); background: transparent; color: var(--avm-muted); cursor: pointer; }
.re4-mchip.in { border: 1px solid var(--re4-ok); background: var(--re4-ok-soft); color: var(--re4-ok); }
.re4-mchip:disabled { border-style: solid; border-color: var(--avm-line); cursor: not-allowed; opacity: .7; }
</style>
