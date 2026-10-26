-- Retours (idées, problèmes, questions) envoyés par l'équipe au « super administrateur ».
alter table public.profiles add column is_super boolean not null default false;
update public.profiles set is_super = true
  where id = (select id from auth.users where lower(email) = 'gabriel.massot@hotmail.com');

create function public.is_super() returns boolean
language sql stable security definer set search_path = '' as $$
  select coalesce((select is_super and active from public.profiles where id = auth.uid()), false)
$$;

create type public.feedback_kind as enum ('probleme','idee','question','autre');
create type public.feedback_status as enum ('nouveau','a_discuter','traite');

create table public.feedback (
  id bigint generated always as identity primary key,
  author uuid not null references public.profiles(id),
  kind public.feedback_kind not null default 'autre',
  message text not null check (char_length(message) between 3 and 4000),
  page text,
  status public.feedback_status not null default 'nouveau',
  reply text check (reply is null or char_length(reply) <= 2000),
  handled_by uuid references public.profiles(id),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);
create index on public.feedback (author, created_at desc);
alter table public.feedback enable row level security;
create policy feedback_read on public.feedback for select to authenticated
  using (author = auth.uid() or public.is_super());
revoke all on public.feedback from anon, authenticated;
grant select on public.feedback to authenticated;

create function public.send_feedback(p_kind public.feedback_kind, p_message text, p_page text default null)
returns bigint language plpgsql security definer set search_path = '' as $$
declare id bigint;
begin
  if public.current_role_name() is null then raise exception 'FORBIDDEN'; end if;
  if char_length(btrim(coalesce(p_message,''))) < 3 then raise exception 'MESSAGE_TOO_SHORT'; end if;
  if (select count(*) from public.feedback where author = auth.uid() and created_at > now() - interval '1 day') >= 30 then
    raise exception 'TOO_MANY';
  end if;
  insert into public.feedback (author, kind, message, page)
    values (auth.uid(), p_kind, left(btrim(p_message), 4000), left(p_page, 80)) returning feedback.id into id;
  return id;
end $$;

create function public.set_feedback_status(p_id bigint, p_status public.feedback_status, p_reply text default null)
returns void language plpgsql security definer set search_path = '' as $$
begin
  if not public.is_super() then raise exception 'FORBIDDEN'; end if;
  update public.feedback set status = p_status, reply = coalesce(nullif(btrim(p_reply), ''), reply),
    handled_by = auth.uid(), updated_at = now() where id = p_id;
  if not found then raise exception 'NOT_FOUND'; end if;
end $$;

revoke execute on all functions in schema public from public, anon;
grant execute on function public.is_super, public.send_feedback, public.set_feedback_status to authenticated;
revoke execute on function public.lock_request, public.cancel_open_tasks, public.zone_owner, public.zone_assign_one, public.link_zones_to_profile from authenticated;
revoke execute on function public.set_zones from authenticated;
