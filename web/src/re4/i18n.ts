import { computed, type Ref } from 'vue';
import type { Re4Snapshot } from './types';

// RE4 页面文案。用词：整套造型 / 状态组 / 选项 / 条件状态 / 预设。不用口语化描述（如"被压过"）。
const zh = {
  title: '差分管理器', loading: '正在连接 REFF…', wait: '等待角色', retry: '重试连接', saving: '正在应用…', dismiss: '关闭',
  character: '角色', onField: '场上', noCharacter: '未找到当前控制角色。进入游戏后会自动显示。', noConfig: '未配置',
  tabQuick: '快速切换', tabBase: '整套造型', tabGroups: '状态组', tabStates: '条件状态', tabPresets: '预设', tabMisc: '杂项',
  // 左侧
  gameState: '游戏状态', hp: 'HP', noTrue: '没有成立的条件', finalMaterials: '最终材质', locatingNow: '定位中：只显示 {0}',
  // 状态与颜色
  kindActive: '生效', kindPartial: '部分生效', kindOutranked: '被覆盖', kindIdle: '未命中', kindOff: '已停用', kindPaused: '条件切换已关闭',
  coveredBy: '被「{0}」覆盖', holding: '保持中', win: '生效', broken: '引用失效',
  // 快速切换
  none: '（无）', groupsHint: '各组只管自己范围里的材质；被条件接管的组会锁定', lockedBy: '由「{0}」接管中，条件结束前不能手动改',
  conditionSwitch: '条件切换', conditionSwitchHint: '关闭后全部按手动选择，条件状态本身保留', conditionTag: '条件',
  noStates: '还没有条件状态', noGroups: '还没有状态组',
  // 整套造型 / 状态组
  baseLead: '整套造型是一份完整快照：每个材质都有开 / 关，同一时间只生效一套。状态组在它上面只覆盖自己管的材质；状态组选「（无）」时，那部分显示的就是这里的样子。',
  groupsLead: '每个状态组先用「编辑范围」划定它管哪些材质，选项只在这个范围里设「- / 关 / 开」，「-」是不管，交给整套造型。',
  notesMode: '备注与定位', notesHint: '打开后，在展开的选项里可以给材质写备注，或点「定位」临时只显示这一块',
  notePlaceholder: '备注', locate: '定位', rename: '重命名', delete: '删除', done: '完成', cancel: '取消', confirmDelete: '确认删除',
  duplicate: '复制', moveUp: '上移', moveDown: '下移', recapture: '从当前模型重新抓取', confirmRecapture: '确认覆写',
  newBase: '新建整套造型（抓取当前外观）', newOption: '新建选项', newGroup: '新建状态组', groupName: '状态组名称',
  editScope: '编辑范围', scopeHint: '勾选这一组要管的材质。一个材质只能属于一个状态组；移出范围时，各选项里这个材质的设置会一起删掉。',
  ownedBy: '已属于「{0}」', optionsCount: '{0} 个选项', baseCount: '{0} 套', materialsCount: '管 {0} 个材质', usedByCount: '{0} 个条件状态在用',
  usedBy: '条件状态在用：', manualIs: '手动：{0}', takenOverBy: '「{0}」接管中', noneOption: '不占用材质，显示整套造型的样子',
  emptyScope: '这一组还没有材质，先点「编辑范围」把材质加进来。', on: '开', off: '关', ignore: '不管',
  countOn: '开 {0}', countOff: '关 {0}', countIgnore: '不管 {0}', deleteWarnUsed: '条件状态「{0}」在用它，删除后会标成引用失效。',
  backupFirst: '会先写一份还原点。', mismatch: '材质不匹配，已跳过', partialSlots: '部分槛位不匹配：{0}',
  armorMirrored: '护甲同步身体外观已开启，护甲不在这里编辑',
  // 条件状态
  orderHint: '从上往下是优先级，拖 ⠿ 调整', expandAll: '全部展开', collapseAll: '全部收起', newState: '新建条件状态',
  stateName: '条件状态名', exclusive: '独占', exclusiveHint: '打开后，这个条件状态命中时，排在下面的条件状态全部被覆盖',
  fadeIn: '渐入', fadeOut: '渐出', seconds: '秒', enabled: '启用', trigger: '触发条件', switchTo: '切换到',
  when: '当', and: '并且', or: '或者', addCondition: '添加条件', noConditions: '没有条件，这个状态不会命中',
  holdLabel: '条件不再满足后，继续保持', now: '现在：{0}', yes: '是', no: '否',
  baseTarget: '整套造型', noSwitch: '不切换', groupTarget: '状态组', addGroupTarget: '添加状态组', noTargets: '不切换任何东西',
  hpDrive: '按血量驱动', hpUpper: '上限 HP%', hpLower: '下限 HP%', hpInvert: '血量越高越接近', hpHint: '不看条件：在上限与下限之间按血量连续溶解',
  catHp: '血量', catCombat: '战斗与武器', catMove: '移动', catDamage: '受击', catOther: '其他',
  unknownCondition: '未知条件', invalidValue: '请输入有效数值', moved: '已删除',
  sentenceWhen: '当{0}', sentenceHold: '（结束后保持 {0} 秒）', sentenceNoCond: '没有条件，不会命中', sentenceHp: '按血量 {0}% → {1}%',
  // 预设
  current: '当前配置', fromPreset: '来自预设「{0}」', noSource: '没有来源预设', fitFull: '完全适用', fitPartial: '部分适用', fitNone: '不适用',
  newPresetName: '新预设名', saveAsPreset: '存为新预设', saveBack: '存回「{0}」', library: '预设库', apply: '套用', confirmApply: '确认套用',
  applyWarn: '套用「{0}」会替换当前配置，当前配置会先存入自动保存。', applyPartial: '部分适用：对不上的槛位会跳过。',
  srcUser: '自己保存', srcMod: '随 mod 发布', isSource: '当前来源', unusable: '不适用（{0}）', noUsable: '没有适用于当前模型的预设',
  betterHint: '当前配置和现在的模型只部分适用。有 {0} 个完全适用的预设：{1}。要不要换由你决定。', notNow: '不用了',
  autosaves: '自动保存（{0} / 5）', autosaveHint: '套用预设前，当前配置会自动存在这里，每个角色保留最近 5 份。', noAutosaves: '还没有自动保存',
  restore: '恢复', promote: '存为预设', restorePoints: '还原点', restoreBackup: '恢复到上次删除 / 覆写之前', restoreOnload: '恢复到本次载入配置时',
  // 杂项
  migrateTitle: '旧配置迁移', migrateLead: '将旧版配置迁移为新版。', migrateButton: '迁移旧配置', detectedOld: '检测到旧版配置', alreadyNew: '已为新版配置',
  migrated: '已迁移为新版配置，迁移前的配置可以用「恢复到上次删除 / 覆写之前」退回。', migratedOverlaps: '{0} 个材质原来被几个状态组同时管，已分给优先级最高的组，请检查。',
  migratedPresets: '旧的命名存档已转成 {0} 个预设。', needMigration: '这份配置还是旧版，需要先迁移。', goMigrate: '去迁移',
  settings: '设置', armorMirror: '护甲同步身体外观', armorMirrorHint: '别关，除非护甲和身体用的不是同一套材质',
  weaponHide: '隐藏收纳武器', uiDissolve: '手动切换时溶解过渡', uiDissolveTime: '时长',
  help: '帮助', loadingHelp: '正在读取帮助…', retryHelp: '重新读取', noHelp: '暂无帮助内容。',
};
const en: Record<keyof typeof zh, string> = {
  title: 'Armor Variant Manager', loading: 'Connecting to REFF…', wait: 'Waiting for a character', retry: 'Retry', saving: 'Applying…', dismiss: 'Dismiss',
  character: 'Character', onField: 'On field', noCharacter: 'No controllable character found. It will appear once you are in game.', noConfig: 'not configured',
  tabQuick: 'Quick switch', tabBase: 'Full outfit', tabGroups: 'State groups', tabStates: 'Condition states', tabPresets: 'Presets', tabMisc: 'Misc',
  gameState: 'Game state', hp: 'HP', noTrue: 'No condition is true', finalMaterials: 'Final materials', locatingNow: 'Locating: only {0} is shown',
  kindActive: 'Effective', kindPartial: 'Partly effective', kindOutranked: 'Overridden', kindIdle: 'Not matched', kindOff: 'Disabled', kindPaused: 'Condition switching is off',
  coveredBy: 'overridden by "{0}"', holding: 'holding', win: 'Effective', broken: 'Missing target',
  none: '(none)', groupsHint: 'Each group only covers its own materials; groups taken over by a condition are locked', lockedBy: 'Taken over by "{0}"; locked until the condition ends',
  conditionSwitch: 'Condition switching', conditionSwitchHint: 'When off, everything follows the manual choice; condition states are kept', conditionTag: 'Cond.',
  noStates: 'No condition states yet', noGroups: 'No state groups yet',
  baseLead: 'A full outfit is a complete snapshot: every material is on or off, and one outfit is in effect at a time. State groups only cover their own materials on top of it; when a group is set to (none), that part shows the outfit.',
  groupsLead: 'Give each state group its materials with "Edit scope"; options set "- / Off / On" only inside that scope. "-" means ignore and leave it to the full outfit.',
  notesMode: 'Notes & locate', notesHint: 'When on, expanded options let you name materials or locate one (show only it for a moment)',
  notePlaceholder: 'Note', locate: 'Locate', rename: 'Rename', delete: 'Delete', done: 'Done', cancel: 'Cancel', confirmDelete: 'Confirm delete',
  duplicate: 'Duplicate', moveUp: 'Move up', moveDown: 'Move down', recapture: 'Recapture from the current model', confirmRecapture: 'Confirm overwrite',
  newBase: 'New full outfit (capture current look)', newOption: 'New option', newGroup: 'New state group', groupName: 'State group name',
  editScope: 'Edit scope', scopeHint: 'Tick the materials this group covers. A material belongs to one group only; removing it also clears it from every option.',
  ownedBy: 'Owned by "{0}"', optionsCount: '{0} options', baseCount: '{0} outfits', materialsCount: '{0} materials', usedByCount: 'used by {0} condition states',
  usedBy: 'Used by: ', manualIs: 'Manual: {0}', takenOverBy: '"{0}" in control', noneOption: 'Covers no material; the full outfit shows through',
  emptyScope: 'This group has no materials yet. Add some with "Edit scope".', on: 'On', off: 'Off', ignore: 'Ignore',
  countOn: 'on {0}', countOff: 'off {0}', countIgnore: 'ignore {0}', deleteWarnUsed: 'Condition state "{0}" uses it and will show a missing target.',
  backupFirst: 'A restore point is written first.', mismatch: 'Materials do not match; skipped', partialSlots: 'Some slots do not match: {0}',
  armorMirrored: 'Armor mirrors body is on; armor is not edited here',
  orderHint: 'Top to bottom is priority; drag ⠿ to reorder', expandAll: 'Expand all', collapseAll: 'Collapse all', newState: 'New condition state',
  stateName: 'Condition state name', exclusive: 'Exclusive', exclusiveHint: 'When on and this state matches, every condition state below it is overridden',
  fadeIn: 'Fade in', fadeOut: 'Fade out', seconds: 's', enabled: 'Enabled', trigger: 'Trigger', switchTo: 'Switch to',
  when: 'When', and: 'and', or: 'or', addCondition: 'Add condition', noConditions: 'No conditions; this state never matches',
  holdLabel: 'Keep it for', now: 'now: {0}', yes: 'Yes', no: 'No',
  baseTarget: 'Full outfit', noSwitch: 'No change', groupTarget: 'State group', addGroupTarget: 'Add state group', noTargets: 'Switches nothing',
  hpDrive: 'Drive by HP', hpUpper: 'Upper HP%', hpLower: 'Lower HP%', hpInvert: 'Higher HP moves toward it', hpHint: 'Ignores conditions: dissolves continuously by HP between the bounds',
  catHp: 'HP', catCombat: 'Combat & weapons', catMove: 'Movement', catDamage: 'Damage', catOther: 'Other',
  unknownCondition: 'Unknown condition', invalidValue: 'Enter a valid number', moved: 'deleted',
  sentenceWhen: 'When {0}', sentenceHold: ' (held {0}s after)', sentenceNoCond: 'No conditions; never matches', sentenceHp: 'By HP {0}% → {1}%',
  current: 'Current config', fromPreset: 'From preset "{0}"', noSource: 'No source preset', fitFull: 'Fits', fitPartial: 'Fits partly', fitNone: 'Does not fit',
  newPresetName: 'New preset name', saveAsPreset: 'Save as new preset', saveBack: 'Save back to "{0}"', library: 'Preset library', apply: 'Apply', confirmApply: 'Confirm apply',
  applyWarn: 'Applying "{0}" replaces the current config; the current config is auto-saved first.', applyPartial: 'Fits partly: slots that do not match are skipped.',
  srcUser: 'Saved by you', srcMod: 'Shipped with a mod', isSource: 'current source', unusable: 'Does not fit ({0})', noUsable: 'No preset fits the current model',
  betterHint: 'The current config only partly fits the model now. {0} preset(s) fit fully: {1}. Switching is up to you.', notNow: 'Not now',
  autosaves: 'Auto-saves ({0} / 5)', autosaveHint: 'Before a preset is applied the current config is kept here; the newest 5 per character are kept.', noAutosaves: 'No auto-saves yet',
  restore: 'Restore', promote: 'Save as preset', restorePoints: 'Restore points', restoreBackup: 'Restore to before the last delete / overwrite', restoreOnload: 'Restore to when this config was loaded',
  migrateTitle: 'Migrate old config', migrateLead: 'Convert the old config to the new format.', migrateButton: 'Migrate old config', detectedOld: 'Old config detected', alreadyNew: 'Already the new format',
  migrated: 'Migrated to the new format. "Restore to before the last delete / overwrite" brings the old config back.', migratedOverlaps: '{0} material(s) were covered by several state groups and now belong to the highest-priority one; please check.',
  migratedPresets: 'Old named saves became {0} preset(s).', needMigration: 'This config is still the old format and needs migrating first.', goMigrate: 'Go migrate',
  settings: 'Settings', armorMirror: 'Armor mirrors body', armorMirrorHint: 'Leave on unless armor and body use different materials',
  weaponHide: 'Hide stowed weapons', uiDissolve: 'Dissolve on manual switches', uiDissolveTime: 'Duration',
  help: 'Help', loadingHelp: 'Loading help…', retryHelp: 'Reload', noHelp: 'No help yet.',
};
export type Re4Key = keyof typeof zh;
export type Re4Translate = (key: Re4Key, ...args: (string | number)[]) => string;

export function useRe4Text(snapshot: Readonly<Ref<Re4Snapshot | null>>) {
  const english = computed(() => snapshot.value?.language === 'en');
  const t: Re4Translate = (key, ...args) => (english.value ? en : zh)[key].replace(/\{(\d)\}/g, (_, i) => String(args[Number(i)] ?? ''));
  return { t, english };
}
