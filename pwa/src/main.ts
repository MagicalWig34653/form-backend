import { mount } from 'svelte';
import './app.css';
import App from './App.svelte';
import { registerServiceWorker } from './lib/sw-register';

const target = document.getElementById('app');
if (!target) throw new Error('Missing #app element');
mount(App, { target });
registerServiceWorker();
