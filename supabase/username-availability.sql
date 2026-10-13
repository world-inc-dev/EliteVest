-- EliteVest username setup
-- Run this once in Supabase Dashboard > SQL Editor.
-- Usernames are chosen by the member; no automatic ID suffix is appended.

create unique index if not exists ev_profiles_username_lower_unique
  on public.ev_profiles (lower(username))
  where username is not null;

create or replace function public.ev_check_username_available(p_username text)
returns boolean
language plpgsql
security definer
set search_path = public
as $$
declare
  v_username text := lower(trim(coalesce(p_username, '')));
begin
  if v_username !~ '^[a-z][a-z0-9._-]{2,19}$'
     or v_username ~ '[._-]$' then
    return false;
  end if;

  return not exists (
    select 1
    from public.ev_profiles p
    where lower(p.username) = v_username
  );
end;
$$;

revoke all on function public.ev_check_username_available(text) from public;
grant execute on function public.ev_check_username_available(text) to anon, authenticated;

create or replace function public.ev_set_username()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  v_username text;
begin
  select lower(trim(u.raw_user_meta_data->>'username'))
    into v_username
  from auth.users u
  where u.id = new.user_id;

  if coalesce(v_username, '') <> '' then
    if v_username !~ '^[a-z][a-z0-9._-]{2,19}$'
       or v_username ~ '[._-]$' then
      raise exception 'Invalid username. Use 3–20 characters, start with a letter, and do not end with punctuation.';
    end if;

    if exists (
      select 1
      from public.ev_profiles p
      where lower(p.username) = v_username
        and p.user_id <> new.user_id
    ) then
      raise exception 'That username is already taken. Please choose another.';
    end if;

    new.username := v_username;
  elsif new.username is null or trim(new.username) = '' then
    -- Legacy/manual profile creation gets a clean name only; no ID suffix is added.
    new.username := lower(regexp_replace(
      coalesce(nullif(trim(new.full_name), ''), 'member'),
      '[^a-zA-Z0-9]+', '_', 'g'
    ));
    new.username := trim(both '_' from new.username);

    if length(new.username) < 3 then
      new.username := 'member';
    end if;

    if exists (
      select 1 from public.ev_profiles p
      where lower(p.username) = lower(new.username)
        and p.user_id <> new.user_id
    ) then
      raise exception 'Choose a unique username when creating this profile.';
    end if;
  end if;

  return new;
end;
$$;

-- The existing ev_profiles trigger should already call ev_set_username().
-- If it does not, enable it with the following trigger:
drop trigger if exists ev_profiles_set_username on public.ev_profiles;
create trigger ev_profiles_set_username
before insert or update of username, full_name on public.ev_profiles
for each row execute function public.ev_set_username();
