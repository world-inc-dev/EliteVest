-- EliteVest: provision unique-looking referral codes for existing and future profiles.
-- Review and run this file in Supabase SQL Editor for project xasbwwafhgcrnlmyaziw.
-- This only fills ev_profiles.referral_code; it does not credit commissions.

create or replace function public.ev_set_referral_code()
returns trigger
language plpgsql
set search_path = public
as $$
begin
  if new.referral_code is null or btrim(new.referral_code) = '' then
    if new.user_id is null then
      raise exception 'A user_id is required to create an EliteVest referral code';
    end if;
    new.referral_code := 'EV' || upper(substr(replace(new.user_id::text, '-', ''), 1, 10));
  end if;
  return new;
end;
$$;

drop trigger if exists ev_profiles_set_referral_code on public.ev_profiles;
create trigger ev_profiles_set_referral_code
before insert or update of user_id, referral_code
on public.ev_profiles
for each row
execute function public.ev_set_referral_code();

update public.ev_profiles
set referral_code = 'EV' || upper(substr(replace(user_id::text, '-', ''), 1, 10))
where (referral_code is null or btrim(referral_code) = '')
  and user_id is not null;
