import { availableParallelism } from 'node:os';

// Leave scheduling capacity for audio and the desktop. Bound each session because
// a recognition model can hold several ONNX sessions at once.
export function windowsCpuThreads(logicalProcessors = availableParallelism()) {
  const count = Number.isFinite(logicalProcessors) ? Math.floor(logicalProcessors) : 1;
  return Math.max(1, Math.min(8, count - 1));
}

export function inferenceSessionOptions(platform = process.platform, logicalProcessors = availableParallelism()) {
  return platform === 'win32'
    ? { intraOpNumThreads: windowsCpuThreads(logicalProcessors), interOpNumThreads: 1, executionMode: 'sequential' }
    : undefined;
}
