# PRUEBAS AL ESTAR EN PC

Ninguna prueba, compilación ni migración se ejecutó durante el cambio de seguridad de 2026-11-01.

## Aplicación de la migración

- [ ] Hacer backup de Supabase antes de cambiar el esquema.
- [ ] En una base de staging con la migración base aplicada, aplicar `202611010001_workspace_integrity_and_evaluation_privacy.sql`.
- [ ] Si aparecen relaciones entre workspaces heredadas, identificar el dueño real de cada registro y repararlas sin borrados automáticos; reintentar la migración.
- [ ] Ejecutar `supabase/verify-security.sql` en staging y confirmar las políticas y triggers nuevos.

## Aislamiento e integridad

- [ ] Intentar vincular en `team_players` un jugador del workspace B con un equipo del A: la base debe rechazarlo.
- [ ] Intentar registrar asistencia de un jugador externo al workspace de la sesión: debe rechazarse.
- [ ] Intentar insertar/editar un partido con `team_id` de otro workspace: debe rechazarse; `team_id=NULL` sigue permitido.
- [ ] Intentar evaluar a un jugador externo usando un `workspace_id` distinto: debe rechazarse.
- [ ] Confirmar que las relaciones válidas dentro del mismo workspace siguen funcionando.
- [ ] Intentar cambiar `workspace_id` de equipos/jugadores/partidos/evaluaciones/competiciones, `training_sessions.team_id`, `workspaces.owner_id` y `player_evaluations.author_id`: deben rechazarse.

## Visibilidad de evaluaciones

- [ ] Usuario autor en el workspace: puede leer su evaluación privada.
- [ ] Otro coach/organizador, incluso el owner: no puede leer ni modificar una evaluación privada ajena.
- [ ] Personal con rol autorizado: puede leer evaluaciones marcadas `staff`; un viewer no puede.
- [ ] El dueño puede modificar/eliminar una evaluación `staff` ajena, sin convertirla en `private`.
- [ ] Un autor que perdió el rol de gestor no puede editar evaluaciones; quien dejó el workspace no puede seguir consultando sus notas privadas.
- [ ] Probar que no quedan políticas RLS anteriores que amplíen el acceso a `player_evaluations`.

## Compatibilidad

- [ ] Aplicar `supabase/schema.sql` en una base vacía y luego aplicar la migración incremental para comprobar que su reejecución no cambia resultados.
- [ ] Comprobar modo invitado local, sincronización opcional Supabase, edición de equipos y panel de entrenador.
- [ ] Revisar el flujo de miembros/roles, permisos desde el navegador y eventuales RPCs que escriban en las tablas.

## Sincronización concurrente (2026-11-01; no ejecutado)

- [ ] En staging aplicar `202611010002_atomic_cloud_backup_cas.sql` con una copia de los backups existentes: confirmar `revision=1` sin perder `payload`.
- [ ] Subir el primer backup por RPC, verificar que la revisión inicial sea 1.
- [ ] Hacer dos cargas con `expectedVersion=1` desde clientes distintos: solo una debe actualizar a revisión 2, la otra debe recibir `CLOUD_CONFLICT`.
- [ ] Al cambiar de cuenta durante una subida, `p_user_id` distinto de `auth.uid()` debe rechazar la RPC.
- [ ] Confirmar que un `upsert` directo a `user_backups` desde `authenticated` queda prohibido.
- [ ] Confirmar que el diálogo de reemplazo explícito puede usar `force=true` y que incrementa revisión.
- [ ] Con un stamp local antiguo (fecha ISO) el cliente debe pedir resolución explícita y nunca sobreescribir sin confirmación.
- [ ] Restaurar un backup remoto y volver a subir sin conflicto si nadie más escribió.
- [ ] Revisar la compatibilidad de `tests/unit/services.test.js` y el adaptador con el contrato RPC real.
