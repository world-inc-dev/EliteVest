-- EliteVest: remove automatically appended hexadecimal ID suffixes from existing usernames.
-- Run once in Supabase SQL Editor after the latest index.html deployment.
-- Only usernames ending in an underscore + 8–12 hexadecimal characters are changed.

BEGIN;

-- Temporarily remove the username trigger so old auth metadata cannot overwrite
-- the cleaned usernames during this one-time migration.
DROP TRIGGER IF EXISTS ev_profiles_set_username ON public.ev_profiles;

DO $$
DECLARE
    r RECORD;
    v_base TEXT;
    v_candidate TEXT;
    v_suffix TEXT;
    v_n INTEGER;
    v_x INTEGER;
    v_alpha TEXT;
BEGIN
    FOR r IN
        SELECT user_id, username
        FROM public.ev_profiles
        WHERE username ~* '_[0-9a-f]{8,12}$'
        ORDER BY user_id
    LOOP
        v_base := regexp_replace(r.username, '_[0-9a-f]{8,12}$', '', 'i');
        v_base := lower(regexp_replace(coalesce(v_base, ''), '[^a-z0-9._-]', '', 'g'));
        v_base := regexp_replace(v_base, '^[^a-z]+', '', '');
        v_base := regexp_replace(v_base, '[._-]+$', '', '');

        IF length(v_base) < 3 THEN
            v_base := 'member';
        END IF;

        v_base := left(v_base, 20);
        v_candidate := v_base;

        -- If another account already uses the clean name, add letters (never digits).
        v_n := 0;
        WHILE EXISTS (
            SELECT 1 FROM public.ev_profiles p
            WHERE lower(p.username) = lower(v_candidate)
              AND p.user_id <> r.user_id
        ) LOOP
            v_n := v_n + 1;
            v_x := v_n;
            v_alpha := '';
            WHILE v_x > 0 LOOP
                v_x := v_x - 1;
                v_alpha := chr(97 + (v_x % 26)) || v_alpha;
                v_x := v_x / 26;
            END LOOP;
            v_suffix := v_alpha;
            v_candidate := left(v_base, 20 - length(v_suffix)) || v_suffix;

            IF v_n > 10000 THEN
                RAISE EXCEPTION 'Could not find a unique username for profile %', r.user_id;
            END IF;
        END LOOP;

        UPDATE public.ev_profiles
        SET username = v_candidate
        WHERE user_id = r.user_id;
    END LOOP;
END;
$$;

-- Restore the validation trigger.
CREATE TRIGGER ev_profiles_set_username
BEFORE INSERT OR UPDATE
ON public.ev_profiles
FOR EACH ROW
EXECUTE FUNCTION public.ev_set_username();

COMMIT;

-- Review the final usernames.
SELECT user_id, username
FROM public.ev_profiles
ORDER BY username;
