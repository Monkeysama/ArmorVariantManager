import { computed, type Ref } from 'vue';
import type { Snapshot } from './types';

const zh = {
  title: '差分管理器', armor: '防具', weapon: '武器', groups: '分组', presets: '预设', parts: '部件材质', settings: '设置', help: '帮助',
  groupName: '分组名称', newGroup: '新分组', global: '全局组', create: '创建分组', delete: '删除', presetName: '预设名称', save: '保存预设',
  setDefault: '设为默认', find: '自动查找预设', main: '主预设', active: '已应用', default: '默认', none: '暂无预设',
  search: '搜索材质', all: '全选', clear: '全不选', showAll: '全部显示', hideAll: '全部隐藏', mesh: '网格', locked: '网格已锁定',
  unavailable: '当前装备无此部件', noMaterials: '此部件没有材质', noMatches: '没有匹配的材质', hidden: '全局隐藏', member: '所属分组',
  selection: '选择分组材质', selecting: '正在选择分组材质', selectionHelp: '勾选材质后创建分组；此模式不改变显隐。',
  selected: '已选', wait: '等待角色与装备', loading: '正在连接 REFF…', saving: '正在应用…', retry: '重试连接',
  restore: '恢复备份', confirmRestore: '从备份恢复当前装备配置？', theme: '界面主题', custom: '自有主题', follow: '跟随 REFF',
  themeHelp: '自有主题使用冰青配色；跟随 REFF 会实时使用公共主题色。', scope: '仅影响差分管理器正文。',
  nativeHelp: '条件变换及游戏专属选项仍在原生差分管理器中设置。', helpTitle: '分组管理显隐，预设保存组合。',
  helpGroups: '普通组内预设互斥；全局组的隐藏优先于其他组。选择分组后，点击预设即可应用。',
  helpSave: '调整网格与材质后输入名称保存。同名预设会被覆盖；默认预设会在装备载入时应用。',
  helpSelection: '打开“选择分组材质”，勾选所需材质并创建分组。退出选择模式后继续调整显隐。',
  helpRestore: '“恢复备份”会从备份覆盖当前装备配置。',
  confirmDelete: '确定删除', cancel: '取消', confirm: '确认删除', suspended: '条件变换暂时挂起',
  visibleCount: '显示', materials: '材质', noParts: '当前没有可用部件', saved: '已保存', created: '已创建分组',
};
type Key = keyof typeof zh;
const en: Record<Key, string> = {
  title: 'Armor Variant Manager', armor: 'Armor', weapon: 'Weapon', groups: 'Groups', presets: 'Presets', parts: 'Parts & materials', settings: 'Settings', help: 'Help',
  groupName: 'Group name', newGroup: 'New group', global: 'Global group', create: 'Create group', delete: 'Delete', presetName: 'Preset name', save: 'Save preset',
  setDefault: 'Set default', find: 'Find presets', main: 'Main presets', active: 'Active', default: 'Default', none: 'No presets yet',
  search: 'Search materials', all: 'Select all', clear: 'Clear selection', showAll: 'Show all', hideAll: 'Hide all', mesh: 'Mesh', locked: 'Mesh locked',
  unavailable: 'Not present on this equipment', noMaterials: 'No materials in this part', noMatches: 'No matching materials', hidden: 'Globally hidden', member: 'Groups',
  selection: 'Select group materials', selecting: 'Selecting group materials', selectionHelp: 'Select materials, then create a group. Visibility is unchanged.',
  selected: 'Selected', wait: 'Waiting for character and equipment', loading: 'Connecting to REFF…', saving: 'Applying…', retry: 'Reconnect',
  restore: 'Restore backup', confirmRestore: 'Restore the current equipment configuration from backup?', theme: 'Interface theme', custom: 'Own theme', follow: 'Follow REFF',
  themeHelp: 'Own theme uses ice cyan. Follow REFF uses the shared colors live.', scope: 'Only affects the Armor Variant Manager content.',
  nativeHelp: 'Use the native manager for conditional transforms and game-specific options.', helpTitle: 'Groups organize visibility. Presets save combinations.',
  helpGroups: 'Presets in a regular group are mutually exclusive. Global groups take priority when hiding. Select a group, then a preset to apply it.',
  helpSave: 'Adjust meshes and materials, then enter a name to save. An existing name overwrites that preset. Default presets apply when equipment loads.',
  helpSelection: 'Enable “Select group materials”, select the materials, and create a group. Leave selection mode to edit visibility again.',
  helpRestore: '“Restore backup” replaces the current equipment configuration with its backup.',
  confirmDelete: 'Delete', cancel: 'Cancel', confirm: 'Delete', suspended: 'Conditional transforms paused',
  visibleCount: 'Visible', materials: 'materials', noParts: 'No parts available', saved: 'Saved', created: 'Group created',
};
export type Translate = (key: Key) => string;
export function useText(snapshot: Ref<Snapshot | null>) {
  const english = computed(() => snapshot.value?.language.toLowerCase().startsWith('en') ?? false);
  const t: Translate = key => (english.value ? en : zh)[key];
  return { t, english };
}
