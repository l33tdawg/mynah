import { defineConfig } from 'vite';

// Store-only simulator fixture. Normal dev/build/pack never load this config.
// Feed sample data into the real reply handler and SDK renderer, not a mock UI.
const sample = 'Your next tasks:\n\n1. Send the venue shortlist\n2. Review the launch plan\n3. Book the team dinner\n\nWant to add anything else?';
export default defineConfig({
  server: { host: '127.0.0.1', port: 5173, strictPort: true },
  plugins: [{
    name: 'store-screenshot-sample',
    apply: 'serve',
    enforce: 'pre',
    transform(code, id) {
      if (!id.endsWith('/src/main.ts')) return;
      const marker = "  const saved = await bridge.getLocalStorage('mynah.connection');";
      if (!code.includes(marker)) throw new Error('Capture hook changed; review the production startup.');
      return code.replace(marker,
        `  weatherCode = 61; desiredWeather = '24°C'; updateClock();\n  receive({type: 'state', text: ${JSON.stringify(JSON.stringify({ status: 'ready', text: '', queueVersion:1, cards:[{id:'demo1',threadId:'demo1',question:'Review the launch plan',answer:'',status:'working'},{id:'demo2',threadId:'demo2',question:'Book the team dinner',answer:'',status:'queued'}] }))}});\n  return;\n${marker}`);
    },
  }],
});
