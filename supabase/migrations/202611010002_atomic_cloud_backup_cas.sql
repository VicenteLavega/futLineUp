-- Secuela de la migración 202611010001. Aplicar en la misma release que el frontend.
begin;

-- Asegura conflicto atómico entre dispositivos al subir backups.
-- La marca updated_at sirve para mostrar fecha; revision es el token de concurrencia.
alter table public.user_backups
  add column if not exists revision bigint not null default 1;

do $revision_constraint$
begin
  if not exists (
    select 1 from pg_constraint
    where conrelid='public.user_backups'::regclass
      and conname='user_backups_revision_positive'
  ) then
    alter table public.user_backups add constraint user_backups_revision_positive
      check (revision > 0);
  end if;
end;
$revision_constraint$;

-- RPC atómica: una precondición nula solo crea si la fila no existe.
-- La rama UPDATE compara revision bajo el bloqueo de fila PostgreSQL;
-- dos dispositivos con la misma revisión no pueden sobrescribirse.
-- Solo force=true (confirmación explícita en el cliente) reemplaza sin CAS.
create or replace function public.save_user_backup(
  p_user_id uuid,
  p_payload jsonb,
  p_expected_revision bigint default null,
  p_force boolean default false
)
returns table(updated_at timestamptz, revision bigint)
language plpgsql security definer
set search_path = ''
as $save$
begin
  if auth.uid() is null or p_user_id is distinct from auth.uid() then
    raise exception 'No autorizado para modificar este backup'
      using errcode = '42501';
  end if;
  if p_payload is null then
    raise exception 'El backup no puede ser nulo' using errcode = '22004';
  end if;
  if p_expected_revision is not null and p_expected_revision <= 0 then
    raise exception 'Revisión inválida' using errcode = '22023';
  end if;

  if coalesce(p_force, false) then
    return query
      insert into public.user_backups as stored(user_id, payload, revision)
      values (p_user_id, p_payload, 1)
      on conflict (user_id) do update
        set payload = excluded.payload,
            revision = stored.revision + 1
      returning stored.updated_at, stored.revision;
  elsif p_expected_revision is null then
    return query
      insert into public.user_backups as stored(user_id, payload, revision)
      values (p_user_id, p_payload, 1)
      on conflict (user_id) do nothing
      returning stored.updated_at, stored.revision;
  else
    return query
      update public.user_backups as stored
        set payload = p_payload,
            revision = stored.revision + 1
      where stored.user_id = p_user_id
        and stored.revision = p_expected_revision
      returning stored.updated_at, stored.revision;
  end if;

  if not found then
    raise exception 'CLOUD_CONFLICT'
      using errcode = 'P0001';
  end if;
end;
$save$;

-- No permitir upserts directos: de otro modo el cliente antiguo podría
-- eludir la comparación de revisiones y destruir el backup reciente.
revoke insert, update on table public.user_backups from public, anon, authenticated;
revoke all on function public.save_user_backup(uuid, jsonb, bigint, boolean)
  from public, anon, authenticated;
grant execute on function public.save_user_backup(uuid, jsonb, bigint, boolean)
  to authenticated;

commit;
