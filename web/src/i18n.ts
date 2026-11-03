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
  restore: '恢复备份', confirmRestore: '恢复备份将覆盖当前装备配置。确定恢复？', backupChanged: '当前装备的主配置文件与备份不同。忽略后，下次成功保存会更新备份。', ignore: '忽略', theme: '界面主题', custom: '自有主题', follow: '跟随 REFF',
  themeHelp: '自有主题使用冰青配色；跟随 REFF 会实时使用公共主题色。', scope: '仅影响差分管理器正文。',
  loadingHelp: '正在读取帮助…', retryHelp: '重新读取', noHelp: '暂无帮助内容。',
  importPreset: '手动导入配置', importWarning: '所选文件将替换当前装备的全部配置，保存后立即应用。',
  refreshImports: '刷新列表', loadingImports: '正在读取配置文件…', importFiles: '选择装备 JSON 或备份', confirmImport: '确认导入',
  noImports: '未找到可导入的装备 JSON 或备份。可刷新列表重试。', importEquipmentChanged: '装备已变化，请刷新列表后重新选择。',
  confirmDelete: '确定删除', cancel: '取消', confirm: '确认删除', suspended: '条件变换暂时挂起',
  visibleCount: '显示', materials: '材质', noParts: '当前没有可用部件', saved: '已保存', created: '已创建分组',
  conditions: '条件变换', conditionMode: '条件模式', singleCondition: '单选', parallelConditions: '并行', enableConditions: '启用条件变换', enableCondition: '启用',
  priority: '优先级', priorityHelp: '数字越小，覆盖优先级越高。', rules: '规则', addRule: '新增规则', deleteRule: '删除规则', noRules: '尚无规则，点击“新增规则”开始配置。',
  ruleTargets: '变换目标', targetGroup: '目标分组', targetPreset: '目标预设', choosePreset: '选择预设', missingTarget: '已不存在', addTarget: '新增目标', removeTarget: '移除目标', noTargets: '添加目标，为此规则指定分组与预设。',
  chainNodes: '链式节点', chainNode: '节点', addNode: '新增节点', removeNode: '移除节点', nodeDuration: '持续时间（秒）', noNodes: '添加节点，按顺序设置每一步的持续时间与目标。',
  conditionTest: '游戏内测试', testHp: 'HP（%）', setHp: '设置 HP', testDamage: '受击测试（减少 25 HP）', noConditions: '当前装备没有可用条件。',
  applyValue: '保存', validNumber: '请输入有效数值',
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
  restore: 'Restore backup', confirmRestore: 'Restoring the backup will overwrite the current equipment configuration. Restore?', backupChanged: 'The current equipment configuration differs from its backup. After ignoring, the next successful save will update the backup.', ignore: 'Ignore', theme: 'Interface theme', custom: 'Own theme', follow: 'Follow REFF',
  themeHelp: 'Own theme uses ice cyan. Follow REFF uses the shared colors live.', scope: 'Only affects the Armor Variant Manager content.',
  loadingHelp: 'Loading help…', retryHelp: 'Reload help', noHelp: 'No help content available.',
  importPreset: 'Import equipment config', importWarning: 'The selected file will replace the entire current equipment configuration, then be saved and applied immediately.',
  refreshImports: 'Refresh list', loadingImports: 'Loading configuration files…', importFiles: 'Choose an equipment JSON or backup', confirmImport: 'Confirm import',
  noImports: 'No equipment JSON files or backups found. Refresh the list to try again.', importEquipmentChanged: 'Equipment has changed. Refresh the list and choose a file again.',
  confirmDelete: 'Delete', cancel: 'Cancel', confirm: 'Delete', suspended: 'Conditional transforms paused',
  visibleCount: 'Visible', materials: 'materials', noParts: 'No parts available', saved: 'Saved', created: 'Group created',
  conditions: 'Conditions', conditionMode: 'Condition mode', singleCondition: 'Single', parallelConditions: 'Parallel', enableConditions: 'Enable conditions', enableCondition: 'Enable',
  priority: 'Priority', priorityHelp: 'Lower numbers have higher override priority.', rules: 'Rules', addRule: 'Add rule', deleteRule: 'Delete rule', noRules: 'No rules yet. Add a rule to configure this condition.',
  ruleTargets: 'Transform targets', targetGroup: 'Target group', targetPreset: 'Target preset', choosePreset: 'Choose a preset', missingTarget: 'Missing', addTarget: 'Add target', removeTarget: 'Remove target', noTargets: 'Add a target to choose a group and preset for this rule.',
  chainNodes: 'Chain nodes', chainNode: 'Node', addNode: 'Add node', removeNode: 'Remove node', nodeDuration: 'Duration (seconds)', noNodes: 'Add nodes to set the duration and targets for each step.',
  conditionTest: 'In-game test', testHp: 'HP (%)', setHp: 'Set HP', testDamage: 'Damage test (−25 HP)', noConditions: 'No conditions available for this equipment.',
  applyValue: 'Save', validNumber: 'Enter a valid number',
};
export type Translate = (key: Key) => string;
export function useText(snapshot: Ref<Snapshot | null>) {
  const english = computed(() => snapshot.value?.language.toLowerCase().startsWith('en') ?? false);
  const t: Translate = key => (english.value ? en : zh)[key];
  return { t, english };
}
