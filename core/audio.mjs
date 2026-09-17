function validateAudio(audio) {
  if (!(audio instanceof Float32Array)) throw new TypeError('Audio must be a Float32Array.');
  for (const value of audio)
    if (!Number.isFinite(value)) throw new RangeError('Audio contains invalid samples.');
}

/** Windowed sinc low-pass filtering avoids folding high frequencies into speech. */
export function resampleAudio(audio, sourceRate, targetRate = 16000) {
  validateAudio(audio);
  if (
    ![sourceRate, targetRate].every(
      (rate) => Number.isFinite(rate) && rate >= 1000 && rate <= 384000,
    )
  )
    throw new RangeError('Unsupported audio sample rate.');
  if (sourceRate === targetRate) return audio.slice();
  const length = Math.floor((audio.length * targetRate) / sourceRate);
  const output = new Float32Array(length);
  const ratio = targetRate / sourceRate;
  const cutoff = Math.min(1, ratio) * 0.94;
  const radius = Math.ceil(24 / Math.min(1, ratio));
  for (let i = 0; i < length; i++) {
    const position = (i + 0.5) / ratio - 0.5;
    const left = Math.max(0, Math.ceil(position - radius));
    const right = Math.min(audio.length - 1, Math.floor(position + radius));
    let total = 0,
      weight = 0;
    for (let j = left; j <= right; j++) {
      const distance = j - position;
      const x = Math.PI * distance * cutoff;
      const sinc = Math.abs(x) < 1e-10 ? 1 : Math.sin(x) / x;
      const window = 0.5 * (1 + Math.cos((Math.PI * distance) / radius));
      const coefficient = cutoff * sinc * window;
      total += audio[j] * coefficient;
      weight += coefficient;
    }
    output[i] = weight ? total / weight : 0;
  }
  return output;
}
