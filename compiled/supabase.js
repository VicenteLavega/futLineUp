// Optional Supabase integration. Configure window.SUPABASE_CONFIG in src/local-config.js.
(function initSupabase() {
  const config = window.SUPABASE_CONFIG;
  const factory = window.supabase?.createClient;
  const unavailable = async () => { throw new Error("Supabase no está configurado"); };
  if (!config?.url || !config?.anonKey || !factory) {
    window.fcSupabase = null;
    window.fcAuth = { configured: false, signInGoogle: unavailable, signInEmail: unavailable, signUpEmail: unavailable, resetPassword: unavailable, updatePassword: unavailable, async signOut() {}, async session() { return null; } };
    return;
  }
  const client = factory(config.url, config.anonKey, { auth: { persistSession: true, autoRefreshToken: true, detectSessionInUrl: true } });
  window.fcSupabase = client;
  const factories = window.fcCloudFactories;
  if (!factories) throw new Error("El núcleo de sincronización no está disponible");
  const remote = factories.createSupabaseBackupAdapter(client);
  const syncStamp = factories.createSyncStamp({ storage: window.localStorage });
  const cloud = factories.createCloudBackupService({
    remote,
    localBackup: { exportData: window.exportFutbolClubData, importData: window.importFutbolClubData },
    validate: window.validateFutbolClubData,
    maxBytes: window.FC_BACKUP_MAX_BYTES,
    syncStamp,
  });
  window.fcCloud = {
    uploadLocal: cloud.upload,
    async downloadToLocal() {
      const result = await cloud.restoreRemote({
        preserveLocal: async (snapshot) => {
          window.downloadJSON(snapshot, `futbolclub-antes-de-sincronizar-${new Date().toISOString().slice(0, 10)}.json`);
        },
      });
      return result.updatedAt;
    },
  };
  window.fcAuth = {
    configured: true,
    async signInGoogle() { return client.auth.signInWithOAuth({ provider: "google", options: { redirectTo: `${location.origin}${location.pathname}#settings` } }); },
    async signInEmail(email, password) { const { data, error } = await client.auth.signInWithPassword({ email, password }); if (error) throw error; return data; },
    async signUpEmail(email, password) { const { data, error } = await client.auth.signUp({ email, password }); if (error) throw error; return data; },
    async resetPassword(email) { const { error } = await client.auth.resetPasswordForEmail(email, { redirectTo: `${location.origin}${location.pathname}#auth` }); if (error) throw error; },
    async updatePassword(password) { const { data, error } = await client.auth.updateUser({ password }); if (error) throw error; return data; },
    async signOut() { return client.auth.signOut(); },
    async session() { return (await client.auth.getSession()).data.session; },
  };
  client.auth.onAuthStateChange((event) => {
    if (event !== "PASSWORD_RECOVERY") return;
    window.fcRecoveryMode = true;
    window.dispatchEvent(new CustomEvent("fc:password-recovery"));
    window.go?.("auth");
  });
})();
//# sourceURL=src/features/auth/infrastructure/supabase.jsx
