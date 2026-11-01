-- futbolClub cloud schema. Run in a new Supabase project.
create extension if not exists pgcrypto;

create table if not exists public.profiles (
  id uuid primary key references auth.users(id) on delete cascade,
  display_name text,
  experience text not null default 'friends' check (experience in ('friends','coach','league')),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);
create table if not exists public.workspaces (
  id uuid primary key default gen_random_uuid(),
  owner_id uuid not null references auth.users(id) on delete cascade,
  name text not null check (char_length(name) between 1 and 120),
  kind text not null default 'friends' check (kind in ('friends','coach','league')),
  created_at timestamptz not null default now()
);
create table if not exists public.workspace_members (
  workspace_id uuid references public.workspaces(id) on delete cascade,
  user_id uuid references auth.users(id) on delete cascade,
  role text not null check (role in ('owner','coach','assistant','delegate','player','guardian','organizer','viewer')),
  primary key (workspace_id,user_id)
);
create table if not exists public.teams (
  id uuid primary key default gen_random_uuid(), workspace_id uuid not null references public.workspaces(id) on delete cascade,
  name text not null check (char_length(name) between 1 and 120), mode smallint not null check(mode in (5,6,7,8,11)), settings jsonb not null default '{}', created_at timestamptz default now(), updated_at timestamptz default now()
);
create table if not exists public.players (
  id uuid primary key default gen_random_uuid(), workspace_id uuid not null references public.workspaces(id) on delete cascade,
  name text not null check (char_length(name) between 1 and 120), birth_date date, preferred_foot text check (preferred_foot is null or preferred_foot in ('left','right','both')), photo_path text, metadata jsonb not null default '{}', archived_at timestamptz, created_at timestamptz default now()
);
create table if not exists public.team_players (
  team_id uuid references public.teams(id) on delete cascade, player_id uuid references public.players(id) on delete cascade,
  number smallint, primary_position text, secondary_position text, active boolean not null default true, primary key(team_id,player_id)
);
create table if not exists public.formations (
  id uuid primary key default gen_random_uuid(), team_id uuid not null references public.teams(id) on delete cascade,
  name text not null check (char_length(name) between 1 and 120), mode smallint not null check(mode in (5,6,7,8,11)), is_free boolean default false, kit jsonb not null default '{}', slots jsonb not null default '[]', substitutes jsonb not null default '[]', updated_at timestamptz default now()
);
create table if not exists public.matches (
  id uuid primary key default gen_random_uuid(), workspace_id uuid not null references public.workspaces(id) on delete cascade,
  team_id uuid references public.teams(id) on delete set null, opponent text not null check (char_length(opponent) between 1 and 120), starts_at timestamptz, venue text, us_score smallint check(us_score>=0), them_score smallint check(them_score>=0), status text default 'scheduled' check(status in ('scheduled','played','cancelled')), metadata jsonb default '{}', created_at timestamptz default now()
);
create table if not exists public.training_sessions (
  id uuid primary key default gen_random_uuid(), team_id uuid not null references public.teams(id) on delete cascade,
  title text not null, starts_at timestamptz not null, notes text, created_at timestamptz default now()
);
create table if not exists public.attendance (
  session_id uuid references public.training_sessions(id) on delete cascade, player_id uuid references public.players(id) on delete cascade,
  status text not null default 'present' check(status in ('present','absent','excused','late')), primary key(session_id,player_id)
);
create table if not exists public.player_evaluations (
  id uuid primary key default gen_random_uuid(), workspace_id uuid not null references public.workspaces(id) on delete cascade,
  player_id uuid not null references public.players(id) on delete cascade, author_id uuid not null references auth.users(id), context text not null,
  rating numeric(3,1) check(rating between 1 and 10), strengths text, improvements text, next_goal text, visibility text not null default 'staff' check(visibility in ('staff','private')), evaluated_on date not null default current_date, created_at timestamptz default now()
);
create table if not exists public.competitions (
  id uuid primary key default gen_random_uuid(), workspace_id uuid not null references public.workspaces(id) on delete cascade, name text not null check(char_length(name) between 1 and 120), season text, rules jsonb default '{}'
);
create table if not exists public.fixtures (
  id uuid primary key default gen_random_uuid(), competition_id uuid not null references public.competitions(id) on delete cascade,
  round_label text, starts_at timestamptz, home_name text not null check(char_length(home_name) between 1 and 120), away_name text not null check(char_length(away_name) between 1 and 120), home_score smallint check(home_score>=0), away_score smallint check(away_score>=0), status text default 'scheduled' check(status in ('scheduled','played','cancelled')), updated_at timestamptz default now()
);

create or replace function public.workspace_role(target uuid) returns text language sql stable security definer set search_path='' as $$
  select case
    when exists(select 1 from public.workspaces w where w.id=target and w.owner_id=auth.uid()) then 'owner'
    else (select m.role from public.workspace_members m where m.workspace_id=target and m.user_id=auth.uid())
  end
$$;
create or replace function public.is_workspace_member(target uuid) returns boolean language sql stable security definer set search_path='' as $$
  select exists(select 1 from public.workspace_members m where m.workspace_id=target and m.user_id=auth.uid())
  or exists(select 1 from public.workspaces w where w.id=target and w.owner_id=auth.uid());
$$;
create or replace function public.can_manage_team(target uuid) returns boolean language sql stable security definer set search_path='' as $$
  select coalesce(public.workspace_role(target) in ('owner','coach','assistant','organizer'), false)
$$;
create or replace function public.can_manage_competition(target uuid) returns boolean language sql stable security definer set search_path='' as $$
  select coalesce(public.workspace_role(target) in ('owner','organizer'), false)
$$;

revoke all on function public.workspace_role(uuid) from public, anon;
revoke all on function public.is_workspace_member(uuid) from public, anon;
revoke all on function public.can_manage_team(uuid) from public, anon;
revoke all on function public.can_manage_competition(uuid) from public, anon;
grant execute on function public.workspace_role(uuid), public.is_workspace_member(uuid), public.can_manage_team(uuid), public.can_manage_competition(uuid) to authenticated;

alter table public.profiles enable row level security;
alter table public.workspaces enable row level security;
alter table public.workspace_members enable row level security;
alter table public.teams enable row level security;
alter table public.players enable row level security;
alter table public.formations enable row level security;
alter table public.matches enable row level security;
alter table public.training_sessions enable row level security;
alter table public.player_evaluations enable row level security;
alter table public.competitions enable row level security;
alter table public.fixtures enable row level security;

drop policy if exists "profile own" on public.profiles;
drop policy if exists "profile own read" on public.profiles;
drop policy if exists "profile own insert" on public.profiles;
drop policy if exists "profile own update" on public.profiles;
drop policy if exists "profile own delete" on public.profiles;
create policy "profile own read" on public.profiles for select using(id=auth.uid());
create policy "profile own insert" on public.profiles for insert with check(id=auth.uid());
create policy "profile own update" on public.profiles for update using(id=auth.uid()) with check(id=auth.uid());
create policy "profile own delete" on public.profiles for delete using(id=auth.uid());

drop policy if exists "workspace members read" on public.workspaces;
drop policy if exists "workspace owner write" on public.workspaces;
drop policy if exists "workspace owner insert" on public.workspaces;
drop policy if exists "workspace owner update" on public.workspaces;
drop policy if exists "workspace owner delete" on public.workspaces;
create policy "workspace members read" on public.workspaces for select using(public.is_workspace_member(id));
create policy "workspace owner insert" on public.workspaces for insert with check(owner_id=auth.uid());
create policy "workspace owner update" on public.workspaces for update using(owner_id=auth.uid()) with check(owner_id=auth.uid());
create policy "workspace owner delete" on public.workspaces for delete using(owner_id=auth.uid());

drop policy if exists "members read" on public.workspace_members;
drop policy if exists "members manage owner" on public.workspace_members;
drop policy if exists "members owner insert" on public.workspace_members;
drop policy if exists "members owner update" on public.workspace_members;
drop policy if exists "members owner delete" on public.workspace_members;
create policy "members read" on public.workspace_members for select using(public.is_workspace_member(workspace_id));
create policy "members owner insert" on public.workspace_members for insert with check(public.workspace_role(workspace_id)='owner');
create policy "members owner update" on public.workspace_members for update using(public.workspace_role(workspace_id)='owner') with check(public.workspace_role(workspace_id)='owner');
create policy "members owner delete" on public.workspace_members for delete using(public.workspace_role(workspace_id)='owner');

drop policy if exists "teams workspace" on public.teams;
drop policy if exists "teams read" on public.teams;
drop policy if exists "teams insert" on public.teams;
drop policy if exists "teams update" on public.teams;
drop policy if exists "teams delete" on public.teams;
create policy "teams read" on public.teams for select using(public.is_workspace_member(workspace_id));
create policy "teams insert" on public.teams for insert with check(public.can_manage_team(workspace_id));
create policy "teams update" on public.teams for update using(public.can_manage_team(workspace_id)) with check(public.can_manage_team(workspace_id));
create policy "teams delete" on public.teams for delete using(public.can_manage_team(workspace_id));

drop policy if exists "players workspace" on public.players;
drop policy if exists "players read" on public.players;
drop policy if exists "players insert" on public.players;
drop policy if exists "players update" on public.players;
drop policy if exists "players delete" on public.players;
create policy "players read" on public.players for select using(public.is_workspace_member(workspace_id));
create policy "players insert" on public.players for insert with check(public.can_manage_team(workspace_id));
create policy "players update" on public.players for update using(public.can_manage_team(workspace_id)) with check(public.can_manage_team(workspace_id));
create policy "players delete" on public.players for delete using(public.can_manage_team(workspace_id));

drop policy if exists "matches workspace" on public.matches;
drop policy if exists "matches read" on public.matches;
drop policy if exists "matches insert" on public.matches;
drop policy if exists "matches update" on public.matches;
drop policy if exists "matches delete" on public.matches;
create policy "matches read" on public.matches for select using(public.is_workspace_member(workspace_id));
create policy "matches insert" on public.matches for insert with check(public.can_manage_team(workspace_id));
create policy "matches update" on public.matches for update using(public.can_manage_team(workspace_id)) with check(public.can_manage_team(workspace_id));
create policy "matches delete" on public.matches for delete using(public.can_manage_team(workspace_id));

drop policy if exists "evaluations workspace" on public.player_evaluations;
drop policy if exists "evaluations staff read" on public.player_evaluations;
drop policy if exists "evaluations author insert" on public.player_evaluations;
drop policy if exists "evaluations author update" on public.player_evaluations;
drop policy if exists "evaluations author delete" on public.player_evaluations;
create policy "evaluations staff read" on public.player_evaluations for select using(public.can_manage_team(workspace_id) or author_id=auth.uid());
create policy "evaluations author insert" on public.player_evaluations for insert with check(public.can_manage_team(workspace_id) and author_id=auth.uid());
create policy "evaluations author update" on public.player_evaluations for update using(author_id=auth.uid() or public.workspace_role(workspace_id)='owner') with check(author_id=auth.uid() or public.workspace_role(workspace_id)='owner');
create policy "evaluations author delete" on public.player_evaluations for delete using(author_id=auth.uid() or public.workspace_role(workspace_id)='owner');

drop policy if exists "competitions workspace" on public.competitions;
drop policy if exists "competitions read" on public.competitions;
drop policy if exists "competitions insert" on public.competitions;
drop policy if exists "competitions update" on public.competitions;
drop policy if exists "competitions delete" on public.competitions;
create policy "competitions read" on public.competitions for select using(public.is_workspace_member(workspace_id));
create policy "competitions insert" on public.competitions for insert with check(public.can_manage_competition(workspace_id));
create policy "competitions update" on public.competitions for update using(public.can_manage_competition(workspace_id)) with check(public.can_manage_competition(workspace_id));
create policy "competitions delete" on public.competitions for delete using(public.can_manage_competition(workspace_id));

drop policy if exists "formations team workspace" on public.formations;
drop policy if exists "formations read" on public.formations;
drop policy if exists "formations write" on public.formations;
create policy "formations read" on public.formations for select using(exists(select 1 from public.teams t where t.id=team_id and public.is_workspace_member(t.workspace_id)));
create policy "formations write" on public.formations for all using(exists(select 1 from public.teams t where t.id=team_id and public.can_manage_team(t.workspace_id))) with check(exists(select 1 from public.teams t where t.id=team_id and public.can_manage_team(t.workspace_id)));

drop policy if exists "training team workspace" on public.training_sessions;
drop policy if exists "training read" on public.training_sessions;
drop policy if exists "training write" on public.training_sessions;
create policy "training read" on public.training_sessions for select using(exists(select 1 from public.teams t where t.id=team_id and public.is_workspace_member(t.workspace_id)));
create policy "training write" on public.training_sessions for all using(exists(select 1 from public.teams t where t.id=team_id and public.can_manage_team(t.workspace_id))) with check(exists(select 1 from public.teams t where t.id=team_id and public.can_manage_team(t.workspace_id)));

drop policy if exists "fixtures competition workspace" on public.fixtures;
drop policy if exists "fixtures read" on public.fixtures;
drop policy if exists "fixtures write" on public.fixtures;
create policy "fixtures read" on public.fixtures for select using(exists(select 1 from public.competitions c where c.id=competition_id and public.is_workspace_member(c.workspace_id)));
create policy "fixtures write" on public.fixtures for all using(exists(select 1 from public.competitions c where c.id=competition_id and public.can_manage_competition(c.workspace_id))) with check(exists(select 1 from public.competitions c where c.id=competition_id and public.can_manage_competition(c.workspace_id)));
create table if not exists public.user_backups (
  user_id uuid primary key references auth.users(id) on delete cascade,
  payload jsonb not null,
  updated_at timestamptz not null default now()
);
alter table public.user_backups drop constraint if exists user_backups_payload_size;
alter table public.user_backups add constraint user_backups_payload_size check (octet_length(payload::text) <= 5242880);
create or replace function public.touch_updated_at() returns trigger language plpgsql set search_path='' as $$
begin
  new.updated_at = now();
  return new;
end;
$$;
drop trigger if exists user_backups_touch_updated_at on public.user_backups;
create trigger user_backups_touch_updated_at before update on public.user_backups for each row execute function public.touch_updated_at();
revoke all on function public.touch_updated_at() from public, anon, authenticated;
alter table public.user_backups enable row level security;
drop policy if exists "backup own" on public.user_backups;
drop policy if exists "backup own read" on public.user_backups;
drop policy if exists "backup own insert" on public.user_backups;
drop policy if exists "backup own update" on public.user_backups;
drop policy if exists "backup own delete" on public.user_backups;
create policy "backup own read" on public.user_backups for select using(user_id=auth.uid());
create policy "backup own insert" on public.user_backups for insert with check(user_id=auth.uid());
create policy "backup own update" on public.user_backups for update using(user_id=auth.uid()) with check(user_id=auth.uid());
create policy "backup own delete" on public.user_backups for delete using(user_id=auth.uid());
-- Policies for join tables added after their parent policies.
alter table public.team_players enable row level security;
alter table public.attendance enable row level security;
drop policy if exists "team players workspace" on public.team_players;
drop policy if exists "team players read" on public.team_players;
drop policy if exists "team players write" on public.team_players;
create policy "team players read" on public.team_players for select using (exists(select 1 from public.teams t where t.id=team_id and public.is_workspace_member(t.workspace_id)));
create policy "team players write" on public.team_players for all using (exists(select 1 from public.teams t where t.id=team_id and public.can_manage_team(t.workspace_id))) with check (exists(select 1 from public.teams t where t.id=team_id and public.can_manage_team(t.workspace_id)));
drop policy if exists "attendance workspace" on public.attendance;
drop policy if exists "attendance read" on public.attendance;
drop policy if exists "attendance write" on public.attendance;
create policy "attendance read" on public.attendance for select using (exists(select 1 from public.training_sessions s join public.teams t on t.id=s.team_id where s.id=session_id and public.is_workspace_member(t.workspace_id)));
create policy "attendance write" on public.attendance for all using (exists(select 1 from public.training_sessions s join public.teams t on t.id=s.team_id where s.id=session_id and public.can_manage_team(t.workspace_id))) with check (exists(select 1 from public.training_sessions s join public.teams t on t.id=s.team_id where s.id=session_id and public.can_manage_team(t.workspace_id)));

create index if not exists workspace_members_user_idx on public.workspace_members(user_id, workspace_id);
create index if not exists teams_workspace_idx on public.teams(workspace_id);
create index if not exists players_workspace_idx on public.players(workspace_id);
create index if not exists matches_workspace_idx on public.matches(workspace_id);
create index if not exists formations_team_idx on public.formations(team_id);
create index if not exists competitions_workspace_idx on public.competitions(workspace_id);
create index if not exists fixtures_competition_idx on public.fixtures(competition_id);

-- Refuerzo de aislamiento y privacidad (también disponible como migración incremental).
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
