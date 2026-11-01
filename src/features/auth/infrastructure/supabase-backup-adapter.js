/** Supabase adapter: never use direct upsert for cloud backups (non-atomic). */
export function createSupabaseBackupAdapter(client) {
  const conflict = () => {
    const error = new Error("Hay una versión más nueva en la nube. Recuperala o confirmá que querés reemplazarla.");
    error.code = "CLOUD_CONFLICT";
    return error;
  };
  const mapError = (error) =>
    error?.message?.includes("CLOUD_CONFLICT") ? conflict() : error;

  return Object.freeze({
    async session() {
      const { data, error } = await client.auth.getSession();
      if (error) throw error;
      return data.session;
    },
    async metadata(userId) {
      const { data, error } = await client.from("user_backups")
        .select("updated_at,revision").eq("user_id", userId).maybeSingle();
      if (error) throw error;
      return data ? { updatedAt: data.updated_at, version: String(data.revision) } : null;
    },
    async upload(userId, payload, { expectedVersion = null, force = false } = {}) {
      let expectedRevision = null;
      if (!force && expectedVersion !== null && expectedVersion !== undefined) {
        const raw = String(expectedVersion);
        const value = Number(raw);
        if (!/^[1-9][0-9]*$/.test(raw) || !Number.isSafeInteger(value)) {
          // Old timestamp-based stamps deliberately require an explicit conflict resolution.
          throw conflict();
        }
        expectedRevision = value;
      }
      const { data, error } = await client.rpc("save_user_backup", {
        p_user_id: userId,
        p_payload: payload,
        p_expected_revision: expectedRevision,
        p_force: force === true,
      }).single();
      if (error) throw mapError(error);
      if (!data || data.revision == null || !data.updated_at)
        throw new Error("Supabase no devolvió la revisión del backup");
      return { updatedAt: data.updated_at, version: String(data.revision) };
    },
    async download(userId) {
      const { data, error } = await client.from("user_backups")
        .select("payload,updated_at,revision").eq("user_id", userId).maybeSingle();
      if (error) throw error;
      return data ? {
        payload: data.payload,
        updatedAt: data.updated_at,
        version: String(data.revision),
      } : null;
    },
  });
}

export function createSyncStamp({ storage, memory = new Map() }) {
  return Object.freeze({
    read(key) { try { return storage.getItem(key) || memory.get(key) || null; } catch { return memory.get(key) || null; } },
    write(key, value) { memory.set(key, value); try { storage.setItem(key, value); } catch { /* memory is the fallback */ } },
  });
}
