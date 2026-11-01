/** Domain orchestration for cloud backup. Only the remote adapter owns CAS writes. */
export function createCloudBackupService({ remote, localBackup, validate, maxBytes, clock = () => new Date(), syncStamp }) {
  const byteLength = (value) => new TextEncoder().encode(JSON.stringify(value)).byteLength;
  async function requireSession() {
    const session = await remote.session();
    if (!session?.user?.id) throw new Error("Iniciá sesión para sincronizar");
    return session;
  }
  const stampKey = (userId) => `fc.cloud.lastSyncAt.${userId}`;
  const versionOf = (record) => record?.version ?? record?.updatedAt ?? null;
  const conflict = () => {
    const error = new Error("Hay una versión más nueva en la nube. Recuperala o confirmá que querés reemplazarla.");
    error.code = "CLOUD_CONFLICT";
    return error;
  };

  async function upload({ force = false } = {}) {
    const session = await requireSession();
    const payload = localBackup.exportData();
    validate(payload);
    if (byteLength(payload) > maxBytes) throw new Error("Tus datos superan el límite de sincronización");
    const key = stampKey(session.user.id);
    const remoteMeta = await remote.metadata(session.user.id);
    const lastSync = syncStamp.read(key);
    // Keep the user-facing early conflict; the database also checks CAS at write time.
    if (!force && remoteMeta && versionOf(remoteMeta) !== lastSync) throw conflict();
    const uploaded = await remote.upload(session.user.id, payload, {
      expectedVersion: force ? null : lastSync,
      force,
    });
    const newVersion = typeof uploaded === "string" ? uploaded : versionOf(uploaded);
    if (newVersion == null) throw new Error("No se recibió revisión remota tras sincronizar");
    syncStamp.write(key, String(newVersion));
    return payload;
  }

  async function restoreRemote({ preserveLocal = async () => {} } = {}) {
    const session = await requireSession();
    const data = await remote.download(session.user.id);
    if (!data?.payload) throw new Error("La cuenta todavía no tiene un backup");
    validate(data.payload);
    const localBefore = localBackup.exportData();
    await preserveLocal(localBefore);
    localBackup.importData(data.payload, "replace");
    syncStamp.write(stampKey(session.user.id), String(versionOf(data) || clock().toISOString()));
    return { updatedAt: data.updatedAt, localBefore };
  }
  return Object.freeze({ upload, restoreRemote, download: restoreRemote });
}
