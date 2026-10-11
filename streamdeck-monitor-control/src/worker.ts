import { spawn, type ChildProcessWithoutNullStreams } from 'node:child_process';
import { existsSync } from 'node:fs';
import path from 'node:path';
import { createInterface } from 'node:readline';
import { EventEmitter } from 'node:events';

export interface WorkerReply<T> {
  result: T;
  warnings: string[];
}

export interface Backend {
  request<T>(op: string, fields?: Record<string, unknown>): Promise<WorkerReply<T>>;
}

export function powerShellCandidates(env: NodeJS.ProcessEnv = process.env): string[] {
  const candidates: string[] = [];
  if (env.ProgramFiles) candidates.push(path.join(env.ProgramFiles, 'PowerShell', '7', 'pwsh.exe'));
  for (const directory of (env.PATH ?? '').split(path.delimiter)) {
    if (directory) candidates.push(path.join(directory.replace(/^"|"$/g, ''), 'pwsh.exe'));
  }
  candidates.push(path.join(env.SystemRoot ?? 'C:\\Windows', 'System32', 'WindowsPowerShell', 'v1.0', 'powershell.exe'));
  return [...new Set(candidates)];
}

export function parseReply(line: string): {
  id: string;
  ok: boolean;
  result?: unknown;
  error?: string;
  warnings?: string[];
} {
  const reply = JSON.parse(line);
  if (
    !reply ||
    typeof reply.id !== 'string' ||
    typeof reply.ok !== 'boolean' ||
    (reply.warnings != null && (!Array.isArray(reply.warnings) || reply.warnings.some((x: unknown) => typeof x !== 'string')))
  ) {
    throw new Error('Invalid response from monitor worker.');
  }
  return reply;
}
interface Pending {
  resolve: (reply: WorkerReply<unknown>) => void;
  reject: (error: Error) => void;
  timer?: NodeJS.Timeout;
}

export class WorkerClient extends EventEmitter implements Backend {
  private child?: ChildProcessWithoutNullStreams;
  private pending = new Map<string, Pending>();
  private serial: Promise<unknown> = Promise.resolve();
  private sequence = 0;
  private failures = 0;
  private retryAt = 0;
  private stopped = false;
  private draining?: Promise<void>;

  constructor(
    private readonly scriptPath: string,
    private readonly logDirectory: string,
    private readonly log: (message: string) => void,
    private readonly executable?: string,
    private readonly queryTimeout = 20000,
    private readonly spawnProcess: typeof spawn = spawn,
  ) {
    super();
  }
  request<T>(op: string, fields: Record<string, unknown> = {}): Promise<WorkerReply<T>> {
    if (!['status', 'rates', 'validateRate', 'apply'].includes(op)) return Promise.reject(new Error('Unsupported worker operation.'));
    const job = this.serial.catch(() => undefined).then(() => this.send<T>(op, fields));
    this.serial = job;
    return job;
  }

  private async start(): Promise<ChildProcessWithoutNullStreams> {
    if (this.stopped) throw new Error('Monitor worker is stopping.');
    await this.draining;
    if (this.child) return this.child;
    const delay = this.retryAt - Date.now();
    if (delay > 0) await new Promise((resolve) => setTimeout(resolve, delay));
    if (this.stopped) throw new Error('Monitor worker is stopping.');
    const executable = this.executable ?? powerShellCandidates().find(existsSync);
    if (!executable) throw new Error('64-bit PowerShell was not found. Install PowerShell 7 or enable Windows PowerShell.');
    const child = this.spawnProcess(
      executable,
      [
        '-NoLogo',
        '-NoProfile',
        '-NonInteractive',
        '-ExecutionPolicy',
        'RemoteSigned',
        '-File',
        this.scriptPath,
        '-LogDirectory',
        this.logDirectory,
      ],
      { windowsHide: true, stdio: 'pipe' },
    );
    this.child = child;
    const lines = createInterface({ input: child.stdout });
    lines.on('line', (line) => {
      try {
        if (line.length > 4 * 1024 * 1024) throw new Error('Worker response exceeds size limit.');
        const reply = parseReply(line);
        const job = this.pending.get(reply.id);
        if (!job) throw new Error('Unexpected response ID from monitor worker.');
        this.pending.delete(reply.id);
        clearTimeout(job.timer);
        this.failures = 0;
        if (reply.ok) job.resolve({ result: reply.result, warnings: reply.warnings ?? [] });
        else job.reject(new Error(reply.error || 'Monitor action failed.'));
      } catch (error) {
        this.draining = new Promise((resolve) =>
          child.once('exit', () => {
            this.draining = undefined;
            resolve();
          }),
        );
        this.fail(child, new Error(`Worker protocol error: ${String(error)}`));
        // A protocol error could occur during a setter. Close input, but never
        // kill that process: let its transaction/rollback finish naturally.
        child.stdin.end();
      }
    });
    child.stderr.on('data', (buffer) => this.log(`PowerShell stderr: ${buffer.toString('utf8').trim()}`));
    child.stdin.on('error', (error) => this.fail(child, error));
    child.on('error', (error) => this.fail(child, error));
    child.on('exit', (code, signal) => {
      lines.close();
      if (this.stopped && this.pending.size === 0) {
        if (this.child === child) this.child = undefined;
        return;
      }
      this.fail(child, new Error(`Monitor worker exited (${code ?? signal ?? 'unknown'}). An interrupted action will not be replayed.`));
    });
    return child;
  }

  private fail(child: ChildProcessWithoutNullStreams, error: Error): void {
    if (this.child !== child) return;
    this.child = undefined;
    this.retryAt = Date.now() + [2000, 5000, 10000, 30000][Math.min(this.failures++, 3)];
    for (const job of this.pending.values()) {
      clearTimeout(job.timer);
      job.reject(error);
    }
    this.pending.clear();
    this.log(error.message);
    this.emit('invalid', error);
  }
  private async send<T>(op: string, fields: Record<string, unknown>): Promise<WorkerReply<T>> {
    const child = await this.start();
    const id = String(++this.sequence);
    return new Promise((resolve, reject) => {
      const job: Pending = { resolve: (reply) => resolve(reply as WorkerReply<T>), reject };
      if (op !== 'apply')
        job.timer = setTimeout(() => {
          this.fail(child, new Error('Read-only monitor query timed out.'));
          child.kill(); // Serialized requests ensure no setter is running.
        }, this.queryTimeout);
      this.pending.set(id, job);
      child.stdin.write(JSON.stringify({ ...fields, id, op }) + '\n', 'utf8', (error) => {
        if (error) this.fail(child, error);
      });
    });
  }

  async close(): Promise<void> {
    this.stopped = true;
    await this.serial.catch(() => undefined);
    this.child?.stdin.end(); // EOF after the current transaction, never a kill.
  }
}
