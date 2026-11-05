import { createApp } from 'vue';
import { installReffUi } from '@reff/ui';
import Root from './Root.vue';
import './style.css';

installReffUi(createApp(Root)).mount('#app');
