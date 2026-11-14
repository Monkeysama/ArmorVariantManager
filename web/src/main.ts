import { createApp } from 'vue';
import { installReffUi } from '@reff/ui';
import App from './App.vue';
import './style.css';
import './world-panel.css';

// WebView2 can enter a blocking Windows drag loop when selected text is dragged.
// Catalog reordering uses pointer events and does not require native drag-and-drop.
document.addEventListener('dragstart', event => event.preventDefault(), { capture: true });

installReffUi(createApp(App)).mount('#app');
