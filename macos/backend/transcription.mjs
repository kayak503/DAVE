// Caption assembly is independent of Whisper and is tested with edge-case timestamps.
export function captionSegments(result, duration, turns = [], groupWords = true) {
  const chunks = result.chunks?.length ? result.chunks : [{ text: result.text, timestamp: [0, duration] }];
  const segments = [];
  for (const chunk of chunks) {
    const text = typeof chunk.text === 'string' ? chunk.text : '';
    if (!text.trim()) continue;
    const pair = chunk.timestamp || [];
    const start = Math.max(0, Math.min(duration, Number.isFinite(pair[0]) ? pair[0] : (segments.at(-1)?.end || 0)));
    const end = Math.max(start, Math.min(duration, Number.isFinite(pair[1]) ? pair[1] : duration));
    if (end <= start) continue;
    // Choose the greatest actual overlap; never invent a label for unvoiced audio.
    let speaker, overlap = 0;
    for (const turn of turns) {
      const amount = Math.max(0, Math.min(end, turn.end) - Math.max(start, turn.start));
      if (amount > overlap) { overlap = amount; speaker = turn.speaker; }
    }
    const previous = segments.at(-1);
    if (groupWords && previous && previous.speaker === speaker && start - previous.end < 0.8 && end - previous.start <= 8 && !/[.!?]["')\]]?\s*$/.test(previous.text)) {
      previous.text += /^\s/.test(text) ? text : ` ${text}`;
      previous.end = Math.max(previous.end, end);
    } else segments.push({ start, end, text: text.trim(), ...(speaker ? { speaker } : {}) });
  }
  return segments.map(s => ({ ...s, text: s.text.trim() }));
}

export function validateJobID(id) {
  if (typeof id !== 'string' || !/^[a-zA-Z0-9_-]{1,100}$/.test(id)) throw new Error('Invalid transcription job identifier.');
  return id;
}
export function validatePCM(audio, maximumSeconds = 60) {
  if (!(audio instanceof Float32Array) || !audio.length || audio.length > maximumSeconds * 16000 || audio.some(x => !Number.isFinite(x) || Math.abs(x) > 1.01)) throw new Error(`Provide up to ${maximumSeconds} seconds of normalized 16 kHz mono audio.`);
}

function unit(vector) {
  const norm = Math.sqrt(vector.reduce((sum, v) => sum + v * v, 0));
  if (!Number.isFinite(norm) || norm < 1e-10) throw new Error('Speaker model returned an invalid embedding.');
  return Float32Array.from(vector, v => v / norm);
}
export class SpeakerClusters {
  constructor(maximum = 32, threshold = 0.55) {
    if (!Number.isInteger(maximum) || maximum < 1 || maximum > 32 || !Number.isFinite(threshold) || threshold < -1 || threshold > 1) throw new Error('Invalid speaker clustering configuration.');
    this.maximum = maximum; this.threshold = threshold; this.centroids = [];
  }
  assign(vector) { return this.assignBatch([vector])[0]; }
  assignBatch(vectors) {
    // Segmentation has already distinguished the voices within this chunk. Match
    // them together so similar voices cannot both claim the same global identity.
    const embeddings = vectors.map(unit);
    const dimension = this.centroids[0]?.vector.length ?? embeddings[0]?.length;
    if (embeddings.some(v => v.length !== dimension)) throw new Error('Speaker embedding dimensions changed.');
    const assignments = new Map(), used = new Set(), candidates = [];
    embeddings.forEach((embedding, input) => this.centroids.forEach((candidate, cluster) => {
      const score = embedding.reduce((sum, v, j) => sum + v * candidate.vector[j], 0);
      candidates.push({ input, cluster, score });
    }));
    candidates.sort((a, b) => b.score - a.score || a.input - b.input || a.cluster - b.cluster);
    for (const { input, cluster, score } of candidates) {
      if (score < this.threshold || assignments.has(input) || used.has(cluster)) continue;
      assignments.set(input, cluster); used.add(cluster);
    }
    for (let input = 0; input < embeddings.length; input++) {
      if (assignments.has(input)) continue;
      if (this.centroids.length < this.maximum) {
        const cluster = this.centroids.length;
        this.centroids.push({ vector: embeddings[input], count: 0 });
        assignments.set(input, cluster); used.add(cluster);
      } else {
        // Honor a user-specified cap, even when segmentation finds more voices.
        // Prefer unused identities before allowing a capped many-to-one match.
        const matches = this.centroids.map((candidate, cluster) => ({
          cluster, score: embeddings[input].reduce((sum, v, j) => sum + v * candidate.vector[j], 0),
        })).sort((a, b) => b.score - a.score || a.cluster - b.cluster);
        const best = matches.find(c => !used.has(c.cluster)) ?? matches[0];
        const cluster = best.cluster;
        assignments.set(input, cluster); used.add(cluster);
      }
    }
    return embeddings.map((embedding, input) => {
      const cluster = assignments.get(input);
      this.update(cluster, embedding);
      return `Speaker ${cluster + 1}`;
    });
  }
  update(index, embedding) {
    const previous = this.centroids[index];
    // Cap history influence so changes in microphone/room can be tracked in long recordings.
    const weight = Math.min(previous.count, 20);
    const combined = embedding.map((v, i) => previous.vector[i] * weight + v);
    // A forced speaker cap can combine opposing embeddings. Keep the existing
    // identity rather than aborting the entire transcript on a zero centroid.
    if (combined.some(v => Math.abs(v) >= 1e-10)) previous.vector = unit(combined);
    previous.count++;
  }
}

// A disjoint timeline preserves speech between detected turns and decodes overlapping
// voices once. A combined label is explicitly ambiguous, never a claimed identity.
export function speakerRegions(turns, duration) {
  const clipped = turns.map(t => ({ ...t, start: Math.max(0, Math.min(duration, t.start)), end: Math.max(0, Math.min(duration, t.end)) })).filter(t => t.end > t.start);
  const boundaries = [...new Set([0, duration, ...clipped.flatMap(t => [t.start, t.end])])].sort((a,b) => a-b);
  const regions = [];
  for (let i=1;i<boundaries.length;i++) {
    const start=boundaries[i-1],end=boundaries[i],mid=(start+end)/2;
    const labels=[...new Set(clipped.filter(t=>t.start<=mid&&t.end>mid).map(t=>t.speaker).filter(Boolean))].sort();
    const speaker=labels.length ? labels.join(' + ') : undefined;
    const previous=regions.at(-1);
    if(previous&&previous.speaker===speaker) previous.end=end;
    else regions.push({start,end,...(speaker?{speaker}:{})});
  }
  // VAD pauses within one person's turn need not cause extra Whisper passes.
  for(let i=1;i<regions.length-1;i++) {
    const before=regions[i-1],gap=regions[i],after=regions[i+1];
    if(!gap.speaker&&gap.end-gap.start<0.8&&before.speaker&&before.speaker===after.speaker) {
      before.end=after.end;regions.splice(i,2);i--;
    }
  }
  return regions;
}

// Remove any interval containing another local voice before embedding a speaker.
// Segmentation IDs are numeric, including zero; do not rely on truthiness.
export function cleanSpeakerTurns(turns, speaker) {
  const boundaries = [...new Set(turns.flatMap(t => [t.start, t.end]))].sort((a, b) => a - b);
  const clean = [];
  for (let i = 1; i < boundaries.length; i++) {
    const start = boundaries[i - 1], end = boundaries[i], mid = (start + end) / 2;
    const active = new Set(turns.filter(t => t.start <= mid && t.end > mid).map(t => t.speaker));
    if (active.size !== 1 || !active.has(speaker)) continue;
    const previous = clean.at(-1);
    if (previous && previous.end === start) previous.end = end;
    else clean.push({ start, end, speaker });
  }
  return clean;
}
