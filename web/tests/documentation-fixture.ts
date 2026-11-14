import type { Documentation, Snapshot } from '../src/types';

// Representative content for navigation, wrapping and game/language switching.
// Production help content is covered by tests/reff_help.lua.
export function documentationFor(game: Snapshot['game'], language: string): Documentation {
  const en = language.startsWith('en');
  const entries = [{
    title: en ? 'Groups and presets' : '分组与预设',
    paragraphs: [en
      ? 'Select a group, then select a preset to apply it. Material edits remain a draft until you save or overwrite a preset.'
      : '选择分组后选择预设即可应用。材质显隐修改属于草稿，新增或覆盖预设后才会写入装备配置。',
    en
      ? 'Global groups have the highest hide priority. Other groups can record visible intent without overriding a global hide.'
      : '全局分组具有最高隐藏优先级。其他分组仍可记录显示意图，但不会覆盖全局隐藏。'],
  }];
  if (game === 'Wilds') entries.push({
    title: en ? 'Ground clipping fix' : '陷地修正',
    paragraphs: [en ? 'Enable the height draft, adjust it, then save a preset.' : '勾选高度草稿，调整后保存为预设。'],
  });
  return { sections: [
    { id: 'configure', title: en ? 'Configuration' : '如何配置', entries },
    { id: 'usage', title: en ? 'Usage' : '如何使用', entries: [{
      title: en ? 'Backups' : '备份',
      paragraphs: [en ? 'Back up your equipment JSON before restoring or importing a configuration.' : '恢复或导入配置前，备份装备 JSON。'],
    }] },
    { id: 'changelog', title: en ? 'Changelog' : '更新日志', heading: en ? 'Changelog (Wilds and Rise)' : '更新日志（《荒野》与《崛起》通用版）', entries: [{
      title: 'V5.0.0', paragraphs: [en ? 'Wilds and Rise now share one installation package.' : '《荒野》和《崛起》共用一个安装包。'],
    }, {
      groupTitle: en ? 'Changelog (Original Wilds Version History)' : '更新日志（原《荒野》版本历史）',
      title: 'V4.3.4', paragraphs: [en ? 'Example entry for checking the version list.' : '用于检查版本列表的示例条目。'],
    }] },
  ] };
}
