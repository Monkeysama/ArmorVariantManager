<script setup lang="ts">
import { computed, provide, shallowRef } from 'vue';
import App from './App.vue';
import Re4App from './re4/Re4App.vue';
import { useAvm } from './useAvm';
import { avmKey } from './avm';

// 一个插件页面服务多款游戏：连接只建一次，拿到第一份快照后按 game 分流。
// 两款 MH 继续用原有页面；RE4 用按自身模型设计的独立页面。
const helpOpen = shallowRef(false);
const avm = useAvm(helpOpen);
provide(avmKey, { ...avm, helpOpen });
const re4 = computed(() => avm.snapshot.value?.game === 'RE4');
</script>

<template>
  <Re4App v-if="re4" />
  <App v-else />
</template>
