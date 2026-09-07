-- Міграція: унікальний код організації (org_code) замість назви як ключа.
-- Для бази, де schema.sql накочено до появи org_code.
--
--   psql "$SURVEY_URL" -v ON_ERROR_STOP=1 -f db/migrate-2026-09-07-org-code.sql
--   psql "$SURVEY_URL" -v ON_ERROR_STOP=1 -f db/schema.sql        -- відтворює представлення
--   psql "$SURVEY_URL" -v ON_ERROR_STOP=1 -f db/neon-grants.sql   -- лише Neon Data API
--
-- Наявним рядкам (заповненим до появи коду) присвоюється по одному коду на
-- company_key, щоб їхні відповіді лишилися зведеними разом. Кожен такий код
-- виводиться в NOTICE — його можна передати координатору тієї організації.

begin;

do $$
begin
  if exists (select 1 from information_schema.columns
             where table_schema = 'public' and table_name = 'responses' and column_name = 'org_code') then
    raise exception 'public.responses уже має org_code — міграція не потрібна';
  end if;
end $$;

-- Представлення залежать від company_key — знімаємо, schema.sql відтворить.
drop view if exists public.v_process_gaps;
drop view if exists public.v_perception_gap;
drop view if exists public.v_industry_benchmark;
drop view if exists public.v_company_summary;

alter table public.responses add column org_code text;

-- Один код на кожну наявну компанію (за старим ключем — назвою).
do $$
declare
  r record;
  alphabet constant text := 'ABCDEFGHJKMNPQRSTUVWXYZ23456789';
  code text;
begin
  for r in select distinct company_key from public.responses loop
    code := '';
    for i in 1..8 loop
      code := code || substr(alphabet, 1 + floor(random() * length(alphabet))::int, 1);
    end loop;
    update public.responses set org_code = code where company_key = r.company_key;
    raise notice 'company "%" -> org_code %', r.company_key, code;
  end loop;
end $$;

alter table public.responses
  alter column org_code set not null,
  add constraint responses_org_code_check check (org_code ~ '^[A-Z0-9]{4,12}$');

drop index if exists public.responses_company_key_idx;
alter table public.responses drop column company_key;
alter table public.responses
  add column company_key text generated always as (lower(org_code)) stored;
create index responses_company_key_idx on public.responses (company_key);

commit;
