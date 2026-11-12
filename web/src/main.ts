import { createApp } from 'vue';
import { installReffUi } from '@reff/ui';
import App from './App.vue';
import './style.css';
import './world-panel.css';

installReffUi(createApp(App)).mount('#app');
