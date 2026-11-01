import test from "node:test";
import assert from "node:assert/strict";
import { createAutomaticBackupService, createBackupScheduler } from "../../src/features/backup/application/automatic-backup-service.js";
import { createCloudBackupService } from "../../src/features/auth/application/cloud-backup-service.js";
import { createSupabaseBackupAdapter, createSyncStamp } from "../../src/features/auth/infrastructure/supabase-backup-adapter.js";
import { createIndexedDbBackupRepository } from "../../src/features/backup/infrastructure/indexeddb-backup-repository.js";

function memoryBackupRepository() {
  const map = new Map();
  return { async list() { return [...map.values()]; }, async put(value) { map.set(value.id, value); }, async remove(id) { map.delete(id); }, map };
}

test("automatic backup throttles, prunes and restores through ports", async () => {
  const repository = memoryBackupRepository();
  let now = new Date("2026-01-01T00:00:00Z"), imported = null, sequence = 0;
  const service = createAutomaticBackupService({
    repository, exportData: () => ({ app: "futbolClub", data: { roster: [sequence++] } }), validate: (value) => value,
    importData: (value, strategy) => { imported = { value, strategy }; }, maxBytes: 10000, clock: () => now,
    idFactory: (createdAt) => `id-${createdAt}`, minIntervalMs: 1000, maxBackups: 2,
  });
  const first = await service.create("first");
  assert.strictEqual(await service.create("throttled"), first);
  now = new Date("2026-01-01T00:00:02Z"); await service.create("second");
  now = new Date("2026-01-01T00:00:04Z"); const third = await service.create("third");
  assert.equal((await service.list()).length, 2);
  assert.equal((await service.latest()).id, third.id);
  const restored = await service.restore(first.id).catch(() => null);
  assert.equal(restored, null, "first backup was pruned");
  const target = (await service.list())[1];
  await service.restore(target.id);
  assert.equal(imported.strategy, "replace"); assert.equal(service.isRestoring(), false);
  assert.ok((await service.list()).some((backup) => backup.reason === "before-restore"));
});

test("automatic backup handles empty payload, size and in-flight de-duplication", async () => {
  const repository = memoryBackupRepository(); let resolvePut;
  repository.put = () => new Promise((resolve) => { resolvePut = resolve; });
  const service = createAutomaticBackupService({ repository, exportData: () => ({ data: { x: 1 } }), validate: (x) => x, importData() {}, maxBytes: 1000, idFactory: () => "id" });
  const a = service.create(), b = service.create(); assert.strictEqual(a, b); resolvePut(); await a;
  const empty = createAutomaticBackupService({ repository: memoryBackupRepository(), exportData: () => ({ data: {} }), validate: (x) => x, importData() {}, maxBytes: 100, idFactory: () => "id" });
  assert.equal(await empty.create(), null);
  const huge = createAutomaticBackupService({ repository: memoryBackupRepository(), exportData: () => ({ data: { x: "x".repeat(1000) } }), validate: (x) => x, importData() {}, maxBytes: 20, idFactory: () => "id" });
  await assert.rejects(() => huge.create(), /límite/);
  await assert.rejects(() => empty.restore("missing"), /No se encontró/);
});

test("backup scheduler is debounce-like and cancelable without real timers", async () => {
  const calls = []; let callback = null, cancelled = false;
  const service = { isRestoring: () => false, async create(reason) { calls.push(reason); } };
  const scheduler = createBackupScheduler({ backupService: service, delayMs: 10, setTimer: (fn) => { callback = fn; return 1; }, clearTimer: () => { cancelled = true; } });
  scheduler.schedule(); scheduler.schedule(); assert.ok(callback); await callback(); assert.deepEqual(calls, ["data-change"]);
  scheduler.schedule(); scheduler.cancel(); assert.equal(cancelled, true);
  const restoring = createBackupScheduler({ backupService: { ...service, isRestoring: () => true }, setTimer: () => { throw Error("should not schedule"); }, clearTimer() {} });
  restoring.schedule();
});

test("cloud backup detects conflict and preserves local snapshot before replace", async () => {
  const stamps = new Map(); let uploaded = null, imported = null;
  const remote = {
    async session() { return { user: { id: "u1" } }; },
    async metadata() { return { updatedAt: "remote-v2" }; },
    async upload(userId, payload) { uploaded = { userId, payload }; return "remote-v3"; },
    async download() { return { payload: { app: "futbolClub", data: { roster: [2] } }, updatedAt: "remote-v4" }; },
  };
  const localBackup = { exportData: () => ({ app: "futbolClub", data: { roster: [1] } }), importData: (payload, strategy) => { imported = { payload, strategy }; } };
  const service = createCloudBackupService({ remote, localBackup, validate: (x) => x, maxBytes: 10000, syncStamp: { read: (k) => stamps.get(k), write: (k, v) => stamps.set(k, v) } });
  await assert.rejects(() => service.upload(), (error) => error.code === "CLOUD_CONFLICT");
  await service.upload({ force: true }); assert.equal(uploaded.userId, "u1"); assert.equal(stamps.get("fc.cloud.lastSyncAt.u1"), "remote-v3");
  const downloaded = await service.download(); assert.deepEqual(downloaded.localBefore.data.roster, [1]); assert.equal(imported.strategy, "replace"); assert.equal(stamps.get("fc.cloud.lastSyncAt.u1"), "remote-v4");
});

test("cloud backup rejects missing sessions, missing remote backup and oversized upload", async () => {
  const base = { localBackup: { exportData: () => ({ data: {} }), importData() {} }, validate: (x) => x, maxBytes: 100, syncStamp: { read: () => null, write() {} } };
  await assert.rejects(() => createCloudBackupService({ ...base, remote: { async session() { return null; } } }).upload(), /Iniciá sesión/);
  const remote = { async session() { return { user: { id: "u" } }; }, async metadata() { return null; }, async download() { return null; } };
  await assert.rejects(() => createCloudBackupService({ ...base, remote }).download(), /todavía no tiene/);
  const huge = createCloudBackupService({ ...base, localBackup: { ...base.localBackup, exportData: () => ({ data: { x: "x".repeat(1000) } }) }, remote: { ...remote, async upload() { throw Error("unreachable"); } } });
  await assert.rejects(() => huge.upload(), /límite/);
});

test("sync stamp falls back to memory when browser storage is denied", () => {
  const stamp = createSyncStamp({ storage: { getItem() { throw Error("denied"); }, setItem() { throw Error("denied"); } } });
  assert.equal(stamp.read("x"), null); stamp.write("x", "1"); assert.equal(stamp.read("x"), "1");
});

test("Supabase adapter maps data shape and errors without leaking query details", async () => {
  const calls = [];
  const chain = { select(value) { calls.push(["select", value]); return this; }, eq(key, value) { calls.push(["eq", key, value]); return this; }, async maybeSingle() { return { data: { payload: { a: 1 }, updated_at: "v1", revision: 4 }, error: null }; }, async single() { return { data: { updated_at: "v2", revision: 5 }, error: null }; } };
  const client = { auth: { async getSession() { return { data: { session: { user: { id: "u" } } } }; } }, from(name) { calls.push(["from", name]); return chain; }, rpc(name, args) { calls.push(["rpc", name, args]); return chain; } };
  const adapter = createSupabaseBackupAdapter(client);
  assert.equal((await adapter.session()).user.id, "u"); assert.equal((await adapter.metadata("u")).version, "4");
  assert.deepEqual(await adapter.upload("u", { a: 1 }, { expectedVersion: "4" }), { updatedAt: "v2", version: "5" });
  assert.equal((await adapter.download("u")).payload.a, 1);
  assert.ok(calls.some(([type, name]) => type === "rpc" && name === "save_user_backup"));
  assert.ok(!calls.some(([type]) => type === "upsert"));
  const failing = createSupabaseBackupAdapter({ auth: client.auth, from() { return { select() { return this; }, eq() { return this; }, async maybeSingle() { return { error: new Error("db") }; } }; } });
  await assert.rejects(() => failing.metadata("u"), /db/);
});

test("IndexedDB adapter rejects absent IndexedDB eagerly", () => {
  assert.throws(() => createIndexedDbBackupRepository({ indexedDB: null }), /no está disponible/);
});
