-- Verificación de solo lectura para ejecutar después de schema.sql en staging.
do $$
declare
  missing_rls text;
  missing_policy text;
begin
  select string_agg(c.relname, ', ')
    into missing_rls
  from pg_class c
  join pg_namespace n on n.oid = c.relnamespace
  where n.nspname = 'public'
    and c.relname = any(array[
      'profiles','workspaces','workspace_members','teams','players',
      'team_players','formations','matches','training_sessions','attendance',
      'player_evaluations','competitions','fixtures','user_backups'
    ])
    and not c.relrowsecurity;
  if missing_rls is not null then
    raise exception 'Tablas sin RLS: %', missing_rls;
  end if;

  select string_agg(required.name, ', ')
    into missing_policy
  from (values
    ('profile own read'), ('workspace members read'), ('members read'),
    ('teams read'), ('players read'), ('matches read'),
    ('evaluations visibility read'), ('competitions read'), ('fixtures read'),
    ('backup own read'), ('team players read'), ('attendance read')
  ) as required(name)
  where not exists (
    select 1 from pg_policies p
    where p.schemaname = 'public' and p.policyname = required.name
  );
  if missing_policy is not null then
    raise exception 'Políticas ausentes: %', missing_policy;
  end if;

  if exists (
    select 1 from (values
      ('team_players'::text, 'team_players_same_workspace'::text),
      ('attendance', 'attendance_same_workspace'),
      ('matches', 'matches_same_workspace'),
      ('player_evaluations', 'player_evaluations_same_workspace'),
      ('workspaces', 'workspaces_owner_immutable'),
      ('teams', 'teams_workspace_immutable'),
      ('players', 'players_workspace_immutable'),
      ('matches', 'matches_workspace_immutable'),
      ('player_evaluations', 'evaluations_workspace_immutable'),
      ('competitions', 'competitions_workspace_immutable'),
      ('training_sessions', 'sessions_team_immutable')
    ) required(table_name, trigger_name)
    where not exists (
      select 1 from pg_trigger tg
      join pg_class c on c.oid = tg.tgrelid
      join pg_namespace ns on ns.oid = c.relnamespace
      where ns.nspname = 'public'
        and c.relname = required.table_name
        and tg.tgname = required.trigger_name
        and not tg.tgisinternal
        and tg.tgenabled in ('O','A')
    )
  ) then
    raise exception 'Faltan triggers de integridad multi-workspace';
  end if;

  if not exists (
    select 1 from pg_constraint
    where conname = 'user_backups_payload_size'
  ) then
    raise exception 'Falta el límite de tamaño de user_backups';
  end if;

  if not exists (
    select 1 from information_schema.columns
    where table_schema='public' and table_name='user_backups'
      and column_name='revision' and data_type='bigint'
  ) then
    raise exception 'Falta revision en user_backups';
  end if;

  if not exists (
    select 1 from pg_proc p join pg_namespace n on n.oid=p.pronamespace
    where n.nspname='public' and p.proname='save_user_backup'
      and p.prosecdef
  ) then
    raise exception 'Falta RPC de respaldo con permisos controlados';
  end if;

  if has_table_privilege('authenticated','public.user_backups','INSERT')
     or has_table_privilege('authenticated','public.user_backups','UPDATE') then
    raise exception 'Permisos DML directos de user_backups siguen abiertos';
  end if;
end $$;

select schemaname, tablename, policyname, cmd, roles, qual, with_check
from pg_policies
where schemaname = 'public'
order by tablename, policyname;
