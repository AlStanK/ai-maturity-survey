-- =============================================================================
-- Індекс ШІ-зрілості організаційної культури — схема бази
-- PostgreSQL 15+ / Supabase
-- Виконати один раз у SQL Editor проєкту.
-- =============================================================================

create extension if not exists pgcrypto;

-- -----------------------------------------------------------------------------
-- Основна таблиця відповідей
-- Гібрид: ключові поля колонками (зручні розрізи в Metabase),
-- повний набір відповідей — у jsonb.
-- -----------------------------------------------------------------------------
create table if not exists public.responses (
  id              uuid primary key default gen_random_uuid(),
  created_at      timestamptz not null default now(),

  -- профіль компанії
  company         text not null check (length(trim(company)) between 2 and 200),
  company_key     text generated always as (lower(trim(company))) stored,
  industry        text,
  company_size    text,
  market          text,
  sensitivity     text,

  -- профіль респондента
  fn              text,          -- функціональний напрям
  tenure          text,
  leads           text,          -- чи є підлеглі

  -- практики
  usage_freq      text,
  account_type    text,
  hours_saved     text,
  shadow_ai       text,

  -- розраховані індекси (1–5)
  ps_index        numeric(4,2),  -- психологічна безпека
  gv_index        numeric(4,2),  -- лідерство та правила
  ef_index        numeric(4,2),  -- сприйнята ефективність
  maturity_now    smallint check (maturity_now between 1 and 4),
  maturity_target smallint check (maturity_target between 1 and 4),

  -- повні дані
  answers         jsonb not null,
  scores          jsonb,
  version         text
);

create index if not exists responses_company_key_idx on public.responses (company_key);
create index if not exists responses_industry_idx    on public.responses (industry);
create index if not exists responses_created_at_idx  on public.responses (created_at desc);
create index if not exists responses_answers_gin     on public.responses using gin (answers);

comment on table public.responses is
  'Анонімні відповіді опитування ШІ-зрілості. Персональних даних немає; email зберігається окремо в public.report_subscribers.';

-- -----------------------------------------------------------------------------
-- Підписка на звіт — окремо від відповідей, щоб email не зв'язувався з анкетою
-- -----------------------------------------------------------------------------
create table if not exists public.report_subscribers (
  id         uuid primary key default gen_random_uuid(),
  created_at timestamptz not null default now(),
  email      text not null check (email ~ '^[^@[:space:]]+@[^@[:space:]]+\.[^@[:space:]]+$')
);

-- -----------------------------------------------------------------------------
-- RLS: анонімний ключ може ТІЛЬКИ додавати. Читання — лише власнику
-- через пряме підключення до Postgres (Metabase) або service_role.
-- Це критично: anon-ключ публічний, він лежить у коді сторінки.
-- -----------------------------------------------------------------------------
alter table public.responses          enable row level security;
alter table public.report_subscribers enable row level security;

-- Роль анонімного відвідувача називається по-різному залежно від того,
-- де крутиться база: anon у Supabase, web_anon у типовій конфігурації
-- PostgREST. Політики створюємо для тієї ролі, яка реально існує.
do $$
declare r text;
begin
  foreach r in array array['anon','web_anon'] loop
    if exists (select 1 from pg_roles where rolname = r) then
      execute format('drop policy if exists responses_insert_%I on public.responses', r);
      execute format(
        'create policy responses_insert_%I on public.responses for insert to %I with check (true)', r, r);

      execute format('drop policy if exists subscribers_insert_%I on public.report_subscribers', r);
      execute format(
        'create policy subscribers_insert_%I on public.report_subscribers for insert to %I with check (true)', r, r);
    end if;
  end loop;
end $$;

-- Політик SELECT / UPDATE / DELETE для anon свідомо НЕМАЄ.
-- Будь-яка спроба прочитати таблицю публічним ключем поверне порожній набір.

-- -----------------------------------------------------------------------------
-- Порогове представлення: компанія показується лише за наявності ≥ 5 анкет.
-- Відповідає правилу конфіденційності дослідження.
-- -----------------------------------------------------------------------------
drop view if exists public.v_company_summary;
create view public.v_company_summary as
select
  company_key                                as company,
  max(industry)                              as industry,
  max(company_size)                          as company_size,
  count(*)                                   as responses,
  round(avg(ps_index), 2)                    as ps_index,
  round(avg(gv_index), 2)                    as gv_index,
  round(avg(ef_index), 2)                    as ef_index,
  round(avg(maturity_now), 2)                as maturity_now,
  round(avg(maturity_target), 2)             as maturity_target,
  round(avg(maturity_target - maturity_now), 2) as maturity_gap,
  min(created_at)                            as first_response,
  max(created_at)                            as last_response
from public.responses
group by company_key
having count(*) >= 5;

comment on view public.v_company_summary is
  'Агрегат по компанії. Компанії з менш ніж 5 відповідями не показуються — вимога анонімності.';

-- -----------------------------------------------------------------------------
-- Галузевий бенчмарк — без назв компаній
-- -----------------------------------------------------------------------------
drop view if exists public.v_industry_benchmark;
create view public.v_industry_benchmark as
select
  industry,
  count(*)                                   as responses,
  count(distinct company_key)                as companies,
  round(avg(ps_index), 2)                    as ps_index,
  round(avg(gv_index), 2)                    as gv_index,
  round(avg(ef_index), 2)                    as ef_index,
  round(avg(maturity_now), 2)                as maturity_now
from public.responses
where industry is not null
group by industry
having count(*) >= 5;

-- -----------------------------------------------------------------------------
-- Розриви за процесами — розгортання jsonb у рядки для Metabase
-- -----------------------------------------------------------------------------
drop view if exists public.v_process_gaps;
create view public.v_process_gaps as
select
  r.id,
  r.company_key,
  r.industry,
  g.idx,
  (r.answers ->> ('proc' || g.idx || '_now'))::text  as now_raw,
  (r.answers ->> ('proc' || g.idx || '_need'))::text as need_raw,
  nullif(r.answers ->> ('proc' || g.idx || '_now'), 'na')::numeric  as val_now,
  nullif(r.answers ->> ('proc' || g.idx || '_need'), 'na')::numeric as val_need,
  nullif(r.answers ->> ('proc' || g.idx || '_need'), 'na')::numeric
    - nullif(r.answers ->> ('proc' || g.idx || '_now'), 'na')::numeric as gap
from public.responses r
cross join generate_series(0, 7) as g(idx);

comment on view public.v_process_gaps is
  'Розрив «потрібно мінус зараз» по кожному з восьми процесів. idx 0–7 у порядку анкети.';

-- -----------------------------------------------------------------------------
-- ВАЖЛИВО: представлення в Postgres виконуються з правами власника й
-- обходять RLS базових таблиць. Без цього блоку анонімний ключ зміг би
-- прочитати v_process_gaps разом із назвами компаній.
-- Читання представлень залишаємо тільки власнику й Metabase
-- (пряме підключення до Postgres або service_role).
-- -----------------------------------------------------------------------------
do $$
declare r text;
begin
  foreach r in array array['anon','authenticated','web_anon'] loop
    if exists (select 1 from pg_roles where rolname = r) then
      execute format('revoke all on public.v_company_summary    from %I', r);
      execute format('revoke all on public.v_industry_benchmark from %I', r);
      execute format('revoke all on public.v_process_gaps       from %I', r);
      execute format('revoke select, update, delete on public.responses          from %I', r);
      execute format('revoke select, update, delete on public.report_subscribers from %I', r);
    end if;
  end loop;

  -- Роль анонімного відвідувача називається по-різному:
  -- anon у Supabase, web_anon у типовій конфігурації PostgREST.
  foreach r in array array['anon','web_anon'] loop
    if exists (select 1 from pg_roles where rolname = r) then
      execute format('grant insert on public.responses          to %I', r);
      execute format('grant insert on public.report_subscribers to %I', r);
    end if;
  end loop;
end $$;
