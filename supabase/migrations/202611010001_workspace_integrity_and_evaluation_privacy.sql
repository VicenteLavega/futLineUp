-- Refuerzo de aislamiento multiusuario. Aplicar después de 202608190001_harden_schema.sql.
-- Instalaciones con relaciones preexistentes inválidas fallan explícitamente.
begin;

-- Rechazar registros heredados incoherentes: nunca mover ni eliminar datos
-- silenciosamente para que una migración de seguridad "pase".
do $integrity$
begin
  if exists (
    select 1 from public.team_players tp
    join public.teams t on t.id = tp.team_id
    join public.players p on p.id = tp.player_id
    where t.workspace_id is distinct from p.workspace_id
  ) then
    raise exception 'team_players contiene relaciones entre workspaces: corregir datos antes de migrar'
      using errcode = '23514';
  end if;

  if exists (
    select 1 from public.attendance a
    join public.training_sessions s on s.id = a.session_id
    join public.teams t on t.id = s.team_id
    join public.players p on p.id = a.player_id
    where t.workspace_id is distinct from p.workspace_id
  ) then
    raise exception 'attendance contiene jugadores ajenos al workspace de la sesión'
      using errcode = '23514';
  end if;

  if exists (
    select 1 from public.matches m
    join public.teams t on t.id = m.team_id
    where m.workspace_id is distinct from t.workspace_id
  ) then
    raise exception 'matches contiene equipos de otro workspace'
      using errcode = '23514';
  end if;

  if exists (
    select 1 from public.player_evaluations e
    join public.players p on p.id = e.player_id
    where e.workspace_id is distinct from p.workspace_id
  ) then
    raise exception 'player_evaluations contiene jugadores de otro workspace'
      using errcode = '23514';
  end if;
end;
$integrity$;

-- Las referencias simples existen gracias a FK, pero la pertenencia al
-- mismo workspace debe validarse también en la base, no en el navegador.
-- SECURITY DEFINER lee relaciones aunque la persona no tenga SELECT sobre
-- la tabla auxiliar; usa nombres calificados y search_path vacío.
create or replace function public.enforce_same_workspace_link()
returns trigger language plpgsql security definer set search_path = '' as $function$
begin
  if TG_TABLE_NAME = 'team_players' then
    if not exists (
      select 1 from public.teams t
      join public.players p on p.id = new.player_id
      where t.id = new.team_id and t.workspace_id = p.workspace_id
    ) then
      raise exception 'El jugador y el equipo deben pertenecer al mismo workspace'
        using errcode = '23514';
    end if;
  elsif TG_TABLE_NAME = 'attendance' then
    if not exists (
      select 1 from public.training_sessions s
      join public.teams t on t.id = s.team_id
      join public.players p on p.id = new.player_id
      where s.id = new.session_id and t.workspace_id = p.workspace_id
    ) then
      raise exception 'El jugador y la sesión deben pertenecer al mismo workspace'
        using errcode = '23514';
    end if;
  elsif TG_TABLE_NAME = 'matches' then
    if new.team_id is not null and not exists (
      select 1 from public.teams t
      where t.id = new.team_id and t.workspace_id = new.workspace_id
    ) then
      raise exception 'El equipo del partido debe pertenecer al workspace'
        using errcode = '23514';
    end if;
  elsif TG_TABLE_NAME = 'player_evaluations' then
    if not exists (
      select 1 from public.players p
      where p.id = new.player_id and p.workspace_id = new.workspace_id
    ) then
      raise exception 'El jugador evaluado debe pertenecer al workspace'
        using errcode = '23514';
    end if;
  else
    raise exception 'enforce_same_workspace_link no admite la tabla %', TG_TABLE_NAME;
  end if;
  return new;
end;
$function$;

-- Congelar los campos de pertenencia impide invalidar posteriormente
-- una relación ya autorizada (por ejemplo, mover un jugador de workspace).
-- Una transferencia legítima requiere un flujo transaccional explícito.
create or replace function public.prevent_workspace_reassignment()
returns trigger language plpgsql set search_path = '' as $function$
begin
  if TG_TABLE_NAME = 'workspaces' then
    if new.owner_id is distinct from old.owner_id then
      raise exception 'owner_id es inmutable: se requiere flujo de transferencia'
        using errcode = '23514';
    end if;
  elsif TG_TABLE_NAME in ('teams', 'players', 'matches', 'player_evaluations', 'competitions') then
    if new.workspace_id is distinct from old.workspace_id then
      raise exception 'workspace_id es inmutable: se requiere flujo de transferencia'
        using errcode = '23514';
    end if;
    if TG_TABLE_NAME = 'player_evaluations'
       and new.author_id is distinct from old.author_id then
      raise exception 'No se puede transferir la autoría de una evaluación'
        using errcode = '23514';
    end if;
  elsif TG_TABLE_NAME = 'training_sessions' then
    if new.team_id is distinct from old.team_id then
      raise exception 'No se puede mover una sesión a otro equipo'
        using errcode = '23514';
    end if;
  else
    raise exception 'prevent_workspace_reassignment no admite la tabla %', TG_TABLE_NAME;
  end if;
  return new;
end;
$function$;

drop trigger if exists team_players_same_workspace on public.team_players;
create trigger team_players_same_workspace
  before insert or update on public.team_players
  for each row execute function public.enforce_same_workspace_link();

drop trigger if exists attendance_same_workspace on public.attendance;
create trigger attendance_same_workspace
  before insert or update on public.attendance
  for each row execute function public.enforce_same_workspace_link();

drop trigger if exists matches_same_workspace on public.matches;
create trigger matches_same_workspace
  before insert or update on public.matches
  for each row execute function public.enforce_same_workspace_link();

drop trigger if exists player_evaluations_same_workspace on public.player_evaluations;
create trigger player_evaluations_same_workspace
  before insert or update on public.player_evaluations
  for each row execute function public.enforce_same_workspace_link();

drop trigger if exists workspaces_owner_immutable on public.workspaces;
create trigger workspaces_owner_immutable
  before update on public.workspaces
  for each row execute function public.prevent_workspace_reassignment();

drop trigger if exists teams_workspace_immutable on public.teams;
create trigger teams_workspace_immutable
  before update on public.teams
  for each row execute function public.prevent_workspace_reassignment();

drop trigger if exists players_workspace_immutable on public.players;
create trigger players_workspace_immutable
  before update on public.players
  for each row execute function public.prevent_workspace_reassignment();

drop trigger if exists matches_workspace_immutable on public.matches;
create trigger matches_workspace_immutable
  before update on public.matches
  for each row execute function public.prevent_workspace_reassignment();

drop trigger if exists evaluations_workspace_immutable on public.player_evaluations;
create trigger evaluations_workspace_immutable
  before update on public.player_evaluations
  for each row execute function public.prevent_workspace_reassignment();

drop trigger if exists competitions_workspace_immutable on public.competitions;
create trigger competitions_workspace_immutable
  before update on public.competitions
  for each row execute function public.prevent_workspace_reassignment();

drop trigger if exists sessions_team_immutable on public.training_sessions;
create trigger sessions_team_immutable
  before update on public.training_sessions
  for each row execute function public.prevent_workspace_reassignment();

-- No otorgar invocación directa de las funciones de triggers a clientes.
revoke all on function public.enforce_same_workspace_link() from public, anon, authenticated;
revoke all on function public.prevent_workspace_reassignment() from public, anon, authenticated;

-- La visibilidad private es solo del autor mientras mantenga membresía.
-- Los roles staff acceden únicamente a evaluaciones con visibility=staff.
-- El dueño puede administrar evaluaciones staff ajenas, pero no privadas.
drop policy if exists "evaluations staff read" on public.player_evaluations;
drop policy if exists "evaluations visibility read" on public.player_evaluations;
create policy "evaluations visibility read"
  on public.player_evaluations for select to authenticated
  using (
    public.is_workspace_member(workspace_id)
    and (
      author_id = auth.uid()
      or (visibility = 'staff' and public.can_manage_team(workspace_id))
    )
  );

drop policy if exists "evaluations author update" on public.player_evaluations;
create policy "evaluations author update"
  on public.player_evaluations for update to authenticated
  using (
    (author_id = auth.uid() and public.can_manage_team(workspace_id))
    or (visibility = 'staff' and public.workspace_role(workspace_id) = 'owner')
  )
  with check (
    (author_id = auth.uid() and public.can_manage_team(workspace_id))
    or (visibility = 'staff' and public.workspace_role(workspace_id) = 'owner')
  );

drop policy if exists "evaluations author delete" on public.player_evaluations;
create policy "evaluations author delete"
  on public.player_evaluations for delete to authenticated
  using (
    (author_id = auth.uid() and public.can_manage_team(workspace_id))
    or (visibility = 'staff' and public.workspace_role(workspace_id) = 'owner')
  );

commit;
