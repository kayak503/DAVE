import test from 'node:test';
import assert from 'node:assert/strict';
import { windowsCpuThreads, inferenceSessionOptions } from '../core/hardware.mjs';

test('Windows inference leaves desktop capacity and bounds large thread pools', () => {
  for (const [cores, threads] of [[1,1],[2,1],[4,3],[8,7],[32,8],[0,1],[NaN,1]]) {
    assert.equal(windowsCpuThreads(cores), threads);
  }
  assert.deepEqual(inferenceSessionOptions('win32', 4), {
    intraOpNumThreads: 3, interOpNumThreads: 1, executionMode: 'sequential',
  });
  assert.equal(inferenceSessionOptions('darwin', 4), undefined);
});
