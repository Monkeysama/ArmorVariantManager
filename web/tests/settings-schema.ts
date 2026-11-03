import type { SettingField, Settings } from '../src/types';

export function settingsFor(game: 'Wilds' | 'Rise'): Settings {
  const english = game === 'Rise';
  const number = (id: string, label: string, value: number, min: number, max: number, step: number): SettingField => ({ id, label, type: 'number', value, min, max, step });
  const shared: SettingField[] = [
    { id: 'language', label: english ? 'Language' : '界面语言', type: 'select', value: english ? 'en' : 'zh', options: [{ value: 'zh', label: '简体中文' }, { value: 'en', label: 'English' }] },
    { id: 'auto_set_selected_preset_as_default', label: english ? 'Automatically set selected preset as default' : '选中预设时自动设为默认', type: 'boolean', value: false },
  ];
  const scanning: SettingField[] = [number('scan_interval', english ? 'Scan Interval (seconds)' : '扫描间隔（秒）', .3, .1, 5, .1), number('body_id_ttl', english ? 'Refresh Interval (seconds)' : '装备标识缓存（秒）', 2, .1, 10, .1), number('scanner_batch_size', english ? 'Scanner Batch Size' : '每批扫描数量', 100, 10, 1000, 10)];
  return { sections: [
    { id: 'general', label: english ? 'General' : '通用', scope: 'global', fields: shared },
    ...(game === 'Rise' ? [
      { id: 'multiplayer', label: 'Multiplayer', scope: 'global' as const, fields: [{ id: 'enable_multiplayer', label: 'Enable multiplayer', type: 'boolean' as const, value: true }] },
      { id: 'transitions', label: 'Dissolve transitions', scope: 'global' as const, fields: [
        { id: 'dissolve_enabled', label: 'Enable dissolve transitions', type: 'boolean' as const, value: true }, number('dissolve_duration', 'Transition duration (seconds)', .3, .1, 2, .01),
      ] },
      { id: 'graphics', label: 'Image quality', scope: 'global' as const, fields: [
        { id: 'enable_image_quality', label: 'Override image quality', type: 'boolean' as const, value: false }, number('image_quality_rate', 'Image quality multiplier', 1, .1, 4, .05),
      ] },
    ] : [{ id: 'performance', label: '装备扫描', scope: 'global' as const, fields: scanning }, { id: 'preview', label: '预览相机', scope: 'global' as const, fields: [
      { id: 'portrait_enabled', label: '启用预览相机', type: 'boolean' as const, value: false },
      number('portrait_camera.distance', '相机距离', 3, 1, 6, .01), number('portrait_camera.horizontal', '水平偏移', 0, -1.5, 1.5, .01), number('portrait_camera.vertical', '垂直偏移', 0, -1.5, 1.5, .01), number('portrait_camera.light_intensity', '光照强度', 1, 0, 2, .01),
      { id: 'portrait_camera.refresh_fps', label: '预览刷新率', type: 'select' as const, value: 30, options: [{ value: 30, label: '30 FPS' }, { value: 60, label: '60 FPS' }, { value: 0, label: '全速' }] },
      { id: 'portrait_camera.reset', label: '重置镜头', type: 'action' as const },
    ] }, { id: 'ground_clipping', label: '陷地修复', description: '当前字段为预设草稿，新建或覆盖预设保存。取消勾选仅退出本预设控制，不撤销之前有效高度；要归零需勾选并设 0。', scope: 'equipment' as const, fields: [
      { id: 'ground_clipping_enabled', label: '参与高度修正', type: 'boolean' as const, value: false }, number('ground_clipping_height_cm', '高度 (cm)', 10, -10, 50, .1),
      { id: 'ground_clipping_reset', label: '归零', type: 'action' as const },
    ] }]),
  ] };
}
