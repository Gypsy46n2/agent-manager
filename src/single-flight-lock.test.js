'use strict';

const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('fs');
const os = require('os');
const path = require('path');
const { spawnSync, spawn } = require('child_process');
const { acquire, release, withLock, lockFilePath } = require('./single-flight-lock.js');

const IS_WINDOWS = process.platform === 'win32';

function makeInstancesDir() {
  return fs.mkdtempSync(path.join(os.tmpdir(), 'single-flight-lock-test-'));
}

// Platform-appropriate "is the lock currently free?" probe. POSIX asks a real bash
// flock -n (the exact contender the production bash lanes use); Windows attempts the
// same atomic create-exclusive the module itself uses (undone immediately if it wins).
function probeFree(dir) {
  if (IS_WINDOWS) {
    try {
      const fd = fs.openSync(lockFilePath(dir), 'wx');
      fs.closeSync(fd);
      fs.unlinkSync(lockFilePath(dir));
      return true;
    } catch {
      return false;
    }
  }
  const result = spawnSync('bash', ['-c', `exec 200>"${lockFilePath(dir)}"; timeout 1 flock -n 200 && echo FREE || echo HELD`]);
  return /FREE/.test(result.stdout.toString());
}

// A real second-process contender built from this module itself -- works identically on
// both platforms, unlike the bash flock contender below (POSIX-only, cross-mechanism).
function spawnNodeContender(dir) {
  const script = `
    const { acquire, release } = require(${JSON.stringify(path.join(__dirname, 'single-flight-lock.js'))});
    const fd = acquire(${JSON.stringify(dir)});
    console.log('ACQUIRED');
    release(fd);
  `;
  return spawn(process.execPath, ['-e', script]);
}

test('lockFilePath matches the exact bash lockfile name (interop depends on this)', () => {
  const dir = makeInstancesDir();
  assert.equal(lockFilePath(dir), path.join(dir, '.pipeline-single-flight.lock'));
});

test('acquire then release: a second acquire() from another process succeeds only after release()', () => {
  const dir = makeInstancesDir();
  const fd1 = acquire(dir);

  // A second acquire from a background child process must block until fd1 is released --
  // verified by timing, not just "eventually returns".
  const start = Date.now();
  const child = spawnNodeContender(dir);
  let out = '';
  child.stdout.on('data', (d) => { out += d; });

  setTimeout(() => release(fd1), 300);

  return new Promise((resolve) => {
    child.on('exit', () => {
      const elapsed = Date.now() - start;
      assert.ok(out.includes('ACQUIRED'));
      assert.ok(elapsed >= 250, `expected the waiter to block until release (~300ms), only waited ${elapsed}ms`);
      resolve();
    });
  });
});

test('a real bash flock process blocks on a Node-held lock and acquires the instant Node releases (cross-mechanism interop)', { skip: IS_WINDOWS && 'bash flock interop is POSIX-only; Windows has no bash lane to interoperate with' }, () => {
  const dir = makeInstancesDir();
  const fd = acquire(dir);

  const result = spawnSync('bash', ['-c', `exec 200>"${lockFilePath(dir)}"; timeout 1 flock -n 200 && echo GOT_IT || echo BLOCKED`]);
  assert.match(result.stdout.toString(), /BLOCKED/, 'a non-blocking flock attempt must fail while Node still holds the lock');

  release(fd);

  const result2 = spawnSync('bash', ['-c', `exec 200>"${lockFilePath(dir)}"; timeout 1 flock -n 200 && echo GOT_IT || echo BLOCKED`]);
  assert.match(result2.stdout.toString(), /GOT_IT/, 'a non-blocking flock attempt must succeed once Node has released');
});

test('a stale lockfile left by a dead holder is reaped instead of deadlocking (Windows crash-recovery)', { skip: !IS_WINDOWS && 'POSIX flock ownership dies with the process; only the Windows lockfile scheme needs reaping' }, () => {
  const dir = makeInstancesDir();
  // Simulate a SIGKILL'd holder: a lockfile whose recorded PID no longer runs. PID 1 is
  // never a live user process on Windows (the idle "process" is 0, System is 4).
  fs.writeFileSync(lockFilePath(dir), '1');
  const handle = acquire(dir);
  assert.ok(handle, 'acquire must reap the dead holder\'s lockfile and take the lock');
  release(handle);
  assert.ok(probeFree(dir), 'lock must be free again after release');
});

test('withLock releases even when the wrapped function throws', async () => {
  const dir = makeInstancesDir();
  await assert.rejects(
    withLock(dir, () => { throw new Error('boom'); }),
    /boom/,
  );

  assert.ok(probeFree(dir), 'withLock must release the lock even after the wrapped function throws');
});

test('withLock releases after a successful async function and returns its value', async () => {
  const dir = makeInstancesDir();
  const value = await withLock(dir, async () => {
    await new Promise((r) => setTimeout(r, 10));
    return 'real-result';
  });
  assert.equal(value, 'real-result');

  assert.ok(probeFree(dir));
});

test('release is safe to call twice (matches release_single_flight_lock()\'s own best-effort semantics)', () => {
  const dir = makeInstancesDir();
  const fd = acquire(dir);
  release(fd);
  assert.doesNotThrow(() => release(fd));
});

test('release(null) is a safe no-op', () => {
  assert.doesNotThrow(() => release(null));
  assert.doesNotThrow(() => release(undefined));
});
