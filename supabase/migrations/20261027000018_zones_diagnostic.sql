-- Cahier des charges 27/10/2026, ATT02 : expliquer pourquoi un dossier n'est pas couvert par une zone.
-- Ajouts uniquement : aucune donnée n'est modifiée.

-- Diagnostic d'une zone (même règle que zone_owner : code postal le plus précis, sinon ville).
-- Retourne la cause et la règle retenue ; ne modifie rien.
create function public.zone_diagnose(p_cp text, p_address text, p_city text)
returns table(status text, rule text, owner uuid)
language plpgsql stable security definer set search_path = '' as $$
declare cp text; best int; n int; holder text; val text;
begin
  cp := coalesce(nullif(regexp_replace(coalesce(p_cp,''), '\s', '', 'g'), ''), substring(coalesce(p_address,'') from '\m[0-9]{5}\M'));
  if cp is not null then
    select max(length(z.value)) into best from public.zone_rules z where z.kind = 'postal' and z.active and cp like z.value || '%';
    if best is not null then
      select count(distinct coalesce(z.user_id::text, 'n:' || public.name_sig(z.label))), min(coalesce(z.user_id::text, 'n:' || public.name_sig(z.label))), min(z.value)
        into n, holder, val from public.zone_rules z
        where z.kind = 'postal' and z.active and cp like z.value || '%' and length(z.value) = best;
      if n <> 1 then return query select 'ambigu'::text, 'code postal ' || val, null::uuid; return; end if;
      if holder like 'n:%' then return query select 'sans_compte'::text, 'code postal ' || val, null::uuid; return; end if;
      if exists (select 1 from public.profiles where id = holder::uuid and active and role = 'commercial') then
        return query select 'ok'::text, 'code postal ' || val, holder::uuid; return;
      end if;
      return query select 'inactif'::text, 'code postal ' || val, null::uuid; return;
    end if;
  end if;
  select count(distinct coalesce(z.user_id::text, 'n:' || public.name_sig(z.label))), min(coalesce(z.user_id::text, 'n:' || public.name_sig(z.label))), min(z.value)
    into n, holder, val from public.zone_rules z
    where z.kind = 'city' and z.active and z.value in (public.norm_city(p_city), public.norm_city(p_address));
  if n = 0 then return query select 'aucune'::text, null::text, null::uuid; return; end if;
  if n > 1 then return query select 'ambigu'::text, 'ville ' || val, null::uuid; return; end if;
  if holder like 'n:%' then return query select 'sans_compte'::text, 'ville ' || val, null::uuid; return; end if;
  if exists (select 1 from public.profiles where id = holder::uuid and active and role = 'commercial') then
    return query select 'ok'::text, 'ville ' || val, holder::uuid; return;
  end if;
  return query select 'inactif'::text, 'ville ' || val, null::uuid;
end $$;

-- Simulation : même périmètre que apply_zones, avec la cause et la règle retenue, sans rien écrire.
create or replace function public.simulate_zones() returns jsonb
language plpgsql stable security definer set search_path = '' as $$
declare r record; c public.contacts; d record; out jsonb := '[]'::jsonb;
begin
  if not public.is_staff() then raise exception 'FORBIDDEN'; end if;
  for r in select id, contact_id from public.requests where assigned_to is null and not archived
      and quality not in ('doublon','spam') and stage not in ('cloture_sans_vente','vente_faite') order by id loop
    select * into c from public.contacts where id = r.contact_id;
    if (c.phone_norm is null and c.email_norm is null) or c.display_name is null then
      out := out || jsonb_build_array(jsonb_build_object('id', r.id, 'status', 'incomplet', 'reason', 'incomplet'));
    else
      select * into d from public.zone_diagnose(c.postal_code, c.address, c.city);
      out := out || jsonb_build_array(jsonb_build_object('id', r.id,
        'status', case when d.status = 'ok' then 'ok' else 'non_couvert' end,
        'reason', d.status, 'rule', d.rule, 'owner', d.owner));
    end if;
  end loop;
  return out;
end $$;

revoke execute on all functions in schema public from public, anon;
revoke execute on function public.zone_diagnose from authenticated;
grant execute on function public.simulate_zones to authenticated;
