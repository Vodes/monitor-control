import { test } from 'node:test';
import assert from 'node:assert/strict';
import { EventEmitter } from 'node:events';
import { PassThrough, Writable } from 'node:stream';
import type { spawn, ChildProcessWithoutNullStreams } from 'node:child_process';
import { WorkerClient, parseReply } from '../src/worker.js';
class FakeProcess extends EventEmitter {
  stdout = new PassThrough();
  stderr = new PassThrough();
  killed = false;
  writes: Record<string, unknown>[] = [];
  args: string[] = [];
  handler: (request: Record<string, unknown>) => void = (request) => {
    this.stdout.write(JSON.stringify({ id: request.id, ok: true, result: [], warnings: [] }) + '\n');
  };
  stdin = new Writable({
    write: (chunk, _encoding, callback) => {
      const request = JSON.parse(chunk.toString());
      this.writes.push(request);
      queueMicrotask(() => this.handler(request));
      callback();
    },
    final: (callback) => {
      this.emit('exit', 0);
      callback();
    },
  });
  kill(): boolean {
    this.killed = true;
    this.emit('exit', 1);
    return true;
  }
}
function client(fake: FakeProcess, timeout = 50): WorkerClient {
  const factory = ((_exe: string, args: string[]) => {
    fake.args = args;
    return fake as unknown as ChildProcessWithoutNullStreams;
  }) as typeof spawn;
  return new WorkerClient('C:\\folder with spaces\\MonitorWorker.ps1', 'C:\\logs', () => {}, 'powershell.exe', timeout, factory);
}
test('protocol validation rejects unstructured noise and bad warning payloads', () => {
  assert.throws(() => parseReply('WARNING: unexpected'));
  assert.throws(() => parseReply('{"id":3,"ok":true}'));
  assert.throws(() => parseReply('{"id":"1","ok":true,"warnings":[false]}'));
  assert.equal(parseReply('{"id":"1","ok":false,"error":"restored"}').ok, false);
});
test('requests use fixed arguments, escaped JSON and serialization, no shell command', async () => {
  const fake = new FakeProcess(),
    worker = client(fake);
  await Promise.all([worker.request('validateRate', { refreshRate: '60000/1001' }), worker.request('rates', { monitorId: 'id " ` $()' })]);
  assert.equal(fake.writes.length, 2);
  assert.equal(fake.writes[1].monitorId, 'id " ` $()');
  assert.equal(fake.args.includes('-Command'), false);
  assert.equal(fake.args.includes('C:\\folder with spaces\\MonitorWorker.ps1'), true);
  assert.equal(fake.args.includes('-NoProfile'), true);
  await assert.rejects(worker.request('exec'), /Unsupported/);
  await worker.close();
});
test('worker errors preserve restoration report without replaying application', async () => {
  const fake = new FakeProcess(),
    worker = client(fake);
  fake.handler = (request) =>
    fake.stdout.write(JSON.stringify({ id: request.id, ok: false, error: 'RESTORATION FAILED: timing rejected.' }) + '\n');
  await assert.rejects(worker.request('apply'), /RESTORATION FAILED/);
  assert.equal(fake.writes.length, 1);
  assert.equal(fake.killed, false);
  await worker.close();
});
test('read-only timeout may kill worker; an apply never receives a timer', async () => {
  const fake = new FakeProcess(),
    worker = client(fake, 20);
  fake.handler = () => {};
  await assert.rejects(worker.request('status'), /timed out/);
  assert.equal(fake.killed, true);
  await worker.close();
  const applying = new FakeProcess(),
    worker2 = client(applying, 15);
  applying.handler = () => {};
  const apply = worker2.request('apply');
  await new Promise((resolve) => setTimeout(resolve, 40));
  assert.equal(applying.killed, false);
  applying.stdout.write(JSON.stringify({ id: applying.writes[0].id, ok: true, result: {}, warnings: [] }) + '\n');
  await apply;
  await worker2.close();
});
test('malformed reply invalidates status and gracefully drains, never kills a setter', async () => {
  const fake = new FakeProcess(),
    worker = client(fake);
  let invalid = false;
  worker.on('invalid', () => {
    invalid = true;
  });
  fake.handler = () => fake.stdout.write('not json\n');
  await assert.rejects(worker.request('apply'), /protocol error/);
  assert.equal(invalid, true);
  assert.equal(fake.killed, false);
  assert.equal(fake.writes.length, 1);
  await worker.close();
});
test('worker crash rejects current apply and never automatically replays it', async () => {
  const fake = new FakeProcess(),
    worker = client(fake);
  fake.handler = () => fake.emit('exit', 9);
  await assert.rejects(worker.request('apply'), /will not be replayed/);
  assert.equal(fake.writes.length, 1);
  await worker.close();
});
