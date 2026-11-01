# Arquitectura

## Dirección

`futbolClub` usa organización **feature-first con capas internas**:

```text
src/
  app/                           # composition root + bridge temporal
  features/
    league/{domain,presentation}
    lineup/{domain,presentation}
    draw/{domain,presentation}
    coach/{domain,presentation}
    backup/{domain,application,infrastructure}
    auth/{application,infrastructure,presentation}
    sharing/{application,presentation}
    ...
  shared/{domain,application,infrastructure,presentation}
```

Dominio importa dominio. Application coordina casos de uso/puertos. Infrastructure implementa adapters. Presentation renderiza y traduce eventos de UI. `shared` no depende de features. `app` compone implementaciones concretas y mantiene el bridge de compatibilidad mientras las entradas de presentación sigan siendo scripts clásicos.

`tests/architecture` comprueba imports, módulos inexistentes, ciclos, globals prohibidos, publicación de facades, modernización de presentaciones y tamaño del core.

## Features extraídas y conectadas

**Liga:** standings, reglas de puntos/desempate, validación de resultados, round-robin, participantes, CSV y copa viven en `features/league/domain`. Las pantallas consumen estas APIs. Al cambiar un resultado de una ronda temprana de Copa se invalidan resultados posteriores para preservar consistencia del cuadro.

**Alineaciones:** `lineup-draft.js` contiene resize/asignación/swap, auto-fill con arquero, suplentes, posiciones libres, selección de modo y snapshot de equipo. Editor usa esas operaciones y queda enfocado en estado/DOM.

**Sorteo:** `TeamBalancer` usa Strategy `count`/`rating`, conserva locks y acepta estrategias adicionales por composición. La UI ya no contiene el algoritmo.

**Entrenador:** asistencia, evaluaciones, tendencia, atributos, objetivos y overview son dominio puro. Coach consume esas funciones y conserva solo interacción/presentación.

**Backups/nube:** `AutomaticBackupService` coordina política/retención/restauración; `BackupScheduler` recibe timers; IndexedDB es adapter. Cloud sync recibe un puerto remoto; Supabase lo implementa. `preserveLocal` ocurre antes de reemplazar estado local.

## SOLID

- **SRP:** reglas, persistencia, scheduling, remote sync y UI tienen razones de cambio distintas.
- **OCP:** validadores/estrategias de backup, puntos/desempates y balanceadores se extienden por composición/registros.
- **LSP:** adapters sustituibles cumplen contract tests comunes.
- **ISP:** casos de uso reciben capacidades mínimas en vez de plataformas completas.
- **DIP:** domain/application no construyen Supabase, IndexedDB, localStorage, timers reales ni React.

Patrones deliberados: Strategy, Adapter, Observer, Composition Root y Facade temporal. No se agregan patrones sin variación/frontera real.

## Persistencia y concurrencia

Ediciones normales pueden degradar a memoria si storage falla y emiten diagnóstico. Importaciones destructivas preparan estado previo y realizan rollback best-effort, sin prometer atomicidad inexistente. Eventos `storage` invalidan snapshots entre pestañas y Playwright contiene una prueba con dos páginas reales.

## Fitness functions

- ADP: ciclos prohibidos.
- Ca/Ce/I: derivados del grafo real.
- A/D: A usa módulos de contrato explícitos como aproximación compatible con JavaScript; D=`|A+I-1|`.
- SDP: se reportan dependencias estable→más inestable.
- SAP: observado con A/I/D.
- CCP/CRP/REP: se revisan con historial de cambio/reuso/release, no con números inventados de una snapshot.

## Tamaño

Core (`domain/application/infrastructure`) tiene límite 300 líneas; presentación nueva, 500. Las pocas excepciones heredadas restantes tienen techos congelados en `scripts/source-quality.mjs` y aparecen como migration debt. Liga, League Setup, Editor, Coach y Draw ya no están en esa lista.

El paso final de largo plazo es convertir las entradas de presentación a ES Modules y eliminar `legacy-bridge.js`. Hasta entonces el bridge solo adapta contratos existentes: no es destino permitido para nuevas reglas.

## Aislamiento multiusuario en Supabase

El modelo conserva **un único workspace por equipo y jugador**. Las RLS de
`teams`, `players`, `matches` y las tablas de relación controlan el acceso,
pero no sustituyen la validación de integridad referencial. Desde la migración
`202611010001_workspace_integrity_and_evaluation_privacy.sql`, cuatro triggers
impiden: jugadores en equipos de otros workspaces, asistencia de jugadores a
sesiones externas, partidos con equipos externos y evaluaciones de jugadores
ajenos. Los triggers se ejecutan en la base y no dependen de la interfaz.

Los campos `workspace_id` de equipos, jugadores, partidos, evaluaciones y
competiciones, `training_sessions.team_id`, `workspaces.owner_id` y
`player_evaluations.author_id` son inmutables. Una transferencia de equipo,
propietario o sesión requiere un flujo transaccional de negocio específico; no
se permite editar el identificador para trasladar datos de forma implícita.

**Evaluaciones:** `visibility='private'` solo puede ser leída por su autor
mientras siga siendo miembro del workspace. `visibility='staff'` permite
lectura a los roles autorizados a gestionar equipos. El dueño puede administrar
evaluaciones de personal, pero no acceder a notas privadas de otros autores ni
convertirlas en privadas. La autoría no se puede transferir.

### Aplicación en proyectos existentes

Aplicar primero la migración base `202608190001_harden_schema.sql` (si aún no
se aplicó) y después `202611010001_workspace_integrity_and_evaluation_privacy.sql`.
Para una base nueva se puede usar `supabase/schema.sql`, que incluye ambas
capas. La migración incremental es transaccional: si detecta relaciones
inconsistentes preexistentes, aborta con un error descriptivo en lugar de borrar
o reasignar registros. Corregir manualmente esos registros con el propietario
correspondiente y volver a aplicar. No ejecutar el esquema base sobre una
instancia existente como sustituto del historial de migraciones.

Las verificaciones pendientes de aplicación y escenarios de permisos están
documentadas en `PRUEBAS_AL_ESTAR_EN_PC.md`.

## Sincronización nube: bloqueo optimista en servidor

El backup remoto en `user_backups` incorpora una `revision bigint` monotónica.
El adaptador `supabase-backup-adapter.js` lee la revisión, no solo `updated_at`.
Antes se consultaban metadatos y luego se hacía `upsert` por separado: dos
dispositivos podían leer la misma versión y sobrescribirse silenciosamente.
Ahora `save_user_backup` compara la revisión y escribe de manera **atómica**
en PostgreSQL; una precondición vacía solo permite crear una fila nueva.

El cliente convierte `CLOUD_CONFLICT` a un error recuperable. La UI conserva
su diálogo explícito antes de forzar el reemplazo. `p_user_id` debe coincidir
con `auth.uid()` en la RPC (incluso si la sesión cambia entre solicitudes).
Se revocan `INSERT` y `UPDATE` directos en la tabla para no admitir
clientes viejos que eludan CAS; `SELECT` y las políticas RLS existentes
permanecen vigentes. La clave local histórica `fc.cloud.lastSyncAt.<uid>`
se mantiene por compatibilidad, aunque su valor nuevo es la revisión en texto.
Un timestamp antiguo provocará conflicto y requerirá resolución explícita,
sin sobrescritura automática.

**Despliegue:** ejecutar en ese orden la base, la migración
`202611010001_workspace_integrity_and_evaluation_privacy.sql` y luego
`202611010002_atomic_cloud_backup_cas.sql`, o usar `schema.sql` en una
base nueva. Publicar el frontend actualizado junto a la nueva RPC; un
cliente antiguo con `upsert` ya no podrá subir backups. No migrar ni
eliminar el contenido de `payload` existente: comienza en revision 1.
