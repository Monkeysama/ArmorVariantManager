import { createApp } from 'vue';
import './reffPreferences';
import { installReffUi } from '@reff/ui';
import Root from './Root.vue';
import './style.css';

installReffUi(createApp(Root)).mount('#app');
