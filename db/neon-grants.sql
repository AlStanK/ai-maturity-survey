-- Індекс ШІ-зрілості організаційної культури — права для Neon Data API
--
-- Neon Data API — керований PostgREST. Анонімний запит виконується роллю,
-- заданою при створенні Data API (--db-anon-role). Використовуємо вбудовану
-- роль Neon `anonymous`: вона зʼявляється в базі в момент увімкнення Data API,
-- тому цей файл застосовувати ПІСЛЯ `neonctl data-api create`.
--
-- Права дзеркалять web_anon зі schema.sql: рівно одна дія — вставити рядок.
-- Читати анонім не може нічого: ані відповіді, ані представлення, ані email.
--
--   psql "$SURVEY_URL" -v ON_ERROR_STOP=1 -f db/neon-grants.sql

begin;

do $$
begin
  if not exists (select 1 from pg_roles where rolname = 'anonymous') then
    raise exception 'Роль anonymous відсутня: спершу увімкнути Neon Data API (neonctl data-api create)';
  end if;
end $$;

grant usage on schema public to anonymous;

revoke all privileges on public.responses, public.report_subscribers from anonymous;
revoke all privileges on public.v_company_summary, public.v_industry_benchmark,
                        public.v_process_gaps, public.v_perception_gap from anonymous;

grant insert on public.responses          to anonymous;
grant insert on public.report_subscribers to anonymous;

-- RLS увімкнено в schema.sql; політики для anonymous — такі самі, як для anon/web_anon.
drop policy if exists responses_insert_anonymous on public.responses;
create policy responses_insert_anonymous on public.responses
  for insert to anonymous with check (true);

drop policy if exists subscribers_insert_anonymous on public.report_subscribers;
create policy subscribers_insert_anonymous on public.report_subscribers
  for insert to anonymous with check (true);

-- Роль authenticated (JWT-користувачі Neon Auth) не використовується:
-- дослідник читає дані через psql роллю власника або Metabase.
revoke all privileges on all tables in schema public from authenticated;

commit;
