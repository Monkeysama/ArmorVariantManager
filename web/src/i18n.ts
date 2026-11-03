import { computed, type Ref } from 'vue';
import type { Snapshot } from './types';

const zh = {
  title: '差分管理器', armor: '防具', weapon: '武器', groups: '分组', presets: '预设', parts: '部件材质', settings: '设置', help: '帮助',
  groupName: '分组名称', newGroup: '新分组', global: '全局组', create: '创建分组', delete: '删除', presetName: '预设名称', save: '保存预设',
  setDefault: '设为默认', find: '自动查找预设', main: '主预设', active: '已应用', default: '默认', none: '暂无预设',
  sort: '排序', finishSort: '完成排序', moveUp: '上移', moveDown: '下移',
  search: '搜索材质', all: '全选', clear: '全不选', showAll: '全部显示', hideAll: '全部隐藏', mesh: '网格', locked: '网格已锁定',
  unavailable: '当前装备无此部件', noMaterials: '此部件没有材质', noMatches: '没有匹配的材质', hidden: '全局隐藏', member: '所属分组',
  selection: '选择分组材质', selecting: '正在选择分组材质', selectionHelp: '勾选材质后创建分组；此模式不改变显隐。',
  selected: '已选', wait: '等待角色与装备', loading: '正在连接 REFF…', saving: '正在应用…', retry: '重试连接',
  restore: '恢复备份', confirmRestore: '从备份恢复当前装备配置？', theme: '界面主题', custom: '自有主题', follow: '跟随 REFF',
  themeHelp: '自有主题使用冰青配色；跟随 REFF 会实时使用公共主题色。', scope: '仅影响差分管理器正文。',
  nativeHelp: '其他游戏专属选项可在原生差分管理器中设置。', helpTitle: '分组管理显隐，预设保存组合。',
  helpGroups: '普通组内预设互斥；全局组的隐藏优先于其他组。选择分组后，点击预设即可应用。',
  helpSave: '调整网格与材质后输入名称保存。同名预设会被覆盖；默认预设会在装备载入时应用。',
  helpSelection: '打开“选择分组材质”，勾选所需材质并创建分组。退出选择模式后继续调整显隐。',
  helpRestore: '“恢复备份”会从备份覆盖当前装备配置。',
  confirmDelete: '确定删除', cancel: '取消', confirm: '确认删除', suspended: '条件变换暂时挂起',
  visibleCount: '显示', materials: '材质', noParts: '当前没有可用部件', saved: '已保存', created: '已创建分组',
  conditions: '条件变换', conditionMode: '条件模式', singleCondition: '单选', parallelConditions: '并行', enableConditions: '启用条件变换', enableCondition: '启用',
  priority: '优先级', priorityHelp: '数字越小，覆盖优先级越高。', rules: '规则', addRule: '新增规则', deleteRule: '删除规则', noRules: '尚无规则，点击“新增规则”开始配置。',
  ruleTargets: '变换目标', targetGroup: '目标分组', targetPreset: '目标预设', choosePreset: '选择预设', missingTarget: '已不存在', addTarget: '新增目标', removeTarget: '移除目标', noTargets: '添加目标，为此规则指定分组与预设。',
  chainNodes: '链式节点', chainNode: '节点', addNode: '新增节点', removeNode: '移除节点', nodeDuration: '持续时间（秒）', noNodes: '添加节点，按顺序设置每一步的持续时间与目标。',
  conditionTest: '游戏内测试', testHp: 'HP（%）', setHp: '设置 HP', testDamage: '受击测试（减少 25 HP）', noConditions: '当前装备没有可用条件。',
  applyValue: '保存', validNumber: '请输入有效数值', helpConditions: '在“条件变换”中选择条件、编辑规则并指定目标。单选只启用选中的条件；并行可同时启用多个条件，数字越小，覆盖优先级越高。数值修改后按 Enter 或离开输入框保存。',
};
type Key = keyof typeof zh;
const en: Record<Key, string> = {
  title: 'Armor Variant Manager', armor: 'Armor', weapon: 'Weapon', groups: 'Groups', presets: 'Presets', parts: 'Parts & materials', settings: 'Settings', help: 'Help',
  groupName: 'Group name', newGroup: 'New group', global: 'Global group', create: 'Create group', delete: 'Delete', presetName: 'Preset name', save: 'Save preset',
  setDefault: 'Set default', find: 'Find presets', main: 'Main presets', active: 'Active', default: 'Default', none: 'No presets yet',
  sort: 'Sort', finishSort: 'Done', moveUp: 'Move up', moveDown: 'Move down',
  search: 'Search materials', all: 'Select all', clear: 'Clear selection', showAll: 'Show all', hideAll: 'Hide all', mesh: 'Mesh', locked: 'Mesh locked',
  unavailable: 'Not present on this equipment', noMaterials: 'No materials in this part', noMatches: 'No matching materials', hidden: 'Globally hidden', member: 'Groups',
  selection: 'Select group materials', selecting: 'Selecting group materials', selectionHelp: 'Select materials, then create a group. Visibility is unchanged.',
  selected: 'Selected', wait: 'Waiting for character and equipment', loading: 'Connecting to REFF…', saving: 'Applying…', retry: 'Reconnect',
  restore: 'Restore backup', confirmRestore: 'Restore the current equipment configuration from backup?', theme: 'Interface theme', custom: 'Own theme', follow: 'Follow REFF',
  themeHelp: 'Own theme uses ice cyan. Follow REFF uses the shared colors live.', scope: 'Only affects the Armor Variant Manager content.',
  nativeHelp: 'Other game-specific options are available in the native manager.', helpTitle: 'Groups organize visibility. Presets save combinations.',
  helpGroups: 'Presets in a regular group are mutually exclusive. Global groups take priority when hiding. Select a group, then a preset to apply it.',
  helpSave: 'Adjust meshes and materials, then enter a name to save. An existing name overwrites that preset. Default presets apply when equipment loads.',
  helpSelection: 'Enable “Select group materials”, select the materials, and create a group. Leave selection mode to edit visibility again.',
  helpRestore: '“Restore backup” replaces the current equipment configuration with its backup.',
  confirmDelete: 'Delete', cancel: 'Cancel', confirm: 'Delete', suspended: 'Conditional transforms paused',
  visibleCount: 'Visible', materials: 'materials', noParts: 'No parts available', saved: 'Saved', created: 'Group created',
  conditions: 'Conditions', conditionMode: 'Condition mode', singleCondition: 'Single', parallelConditions: 'Parallel', enableConditions: 'Enable conditions', enableCondition: 'Enable',
  priority: 'Priority', priorityHelp: 'Lower numbers have higher override priority.', rules: 'Rules', addRule: 'Add rule', deleteRule: 'Delete rule', noRules: 'No rules yet. Add a rule to configure this condition.',
  ruleTargets: 'Transform targets', targetGroup: 'Target group', targetPreset: 'Target preset', choosePreset: 'Choose a preset', missingTarget: 'Missing', addTarget: 'Add target', removeTarget: 'Remove target', noTargets: 'Add a target to choose a group and preset for this rule.',
  chainNodes: 'Chain nodes', chainNode: 'Node', addNode: 'Add node', removeNode: 'Remove node', nodeDuration: 'Duration (seconds)', noNodes: 'Add nodes to set the duration and targets for each step.',
  conditionTest: 'In-game test', testHp: 'HP (%)', setHp: 'Set HP', testDamage: 'Damage test (−25 HP)', noConditions: 'No conditions available for this equipment.',
  applyValue: 'Save', validNumber: 'Enter a valid number', helpConditions: 'Choose a condition, edit its rules, and set its targets. Single mode runs only the selected condition. Parallel mode can enable several; lower numbers have higher override priority. Press Enter or leave a number field to save.',
};
export type Translate = (key: Key) => string;
export function useText(snapshot: Ref<Snapshot | null>) {
  const english = computed(() => snapshot.value?.language.toLowerCase().startsWith('en') ?? false);
  const t: Translate = key => (english.value ? en : zh)[key];
  return { t, english };
}
