import { shallowRef } from 'vue';

// REFF Shell 发来的语言偏好('zh-CN' / 'en-US')。installReffUi 一装好桥接就会请求偏好,
// 回包可能早于页面组件挂载,所以监听要在 main.ts 调用 installReffUi 之前注册(先 import 本文件)。
export const reffLanguage = shallowRef<string | null>(null);

window.addEventListener('reff:preferences-changed', event => {
  const language = (event as CustomEvent<{ language?: unknown }>).detail?.language;
  if (typeof language === 'string') reffLanguage.value = language;
});
