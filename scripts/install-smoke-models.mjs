import path from 'node:path';
import { SpeechEngine } from '../core/engine.mjs';
let previous = '';
const engine = new SpeechEngine({
  modelDir: path.resolve('.cache/models'),
  onProgress: (e) => {
    const key = `${e.modelId}: ${e.status} ${Math.floor((e.progress ?? 0) / 10) * 10}%`;
    if (key !== previous) {
      console.log(key);
      previous = key;
    }
  },
});
for (const id of ['whisper-tiny', 'kokoro-q8', 'flan-t5-small']) {
  const models = await engine.listModels();
  if (!models.find((m) => m.id === id)?.installed) await engine.installModel(id);
}
await engine.dispose();
console.log('LOCALVOICE_MODELS_INSTALLED');
