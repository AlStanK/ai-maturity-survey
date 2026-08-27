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

  -- достовірність оцінки: наскільки відповіді цієї людини можна
  -- переносити на всю організацію
  coverage_scope  text,           -- яку частину компанії респондент бачить
  ai_awareness    text,           -- обізнаність про ініціативи з ШІ
  confidence      smallint check (confidence between 0 and 100),
  unknown_share   numeric(4,2),   -- частка «Н/З» серед питань про компанію
  policy_known    boolean,        -- чи знає респондент про правила роботи з даними
  claim_supported boolean,        -- заявлений рівень підтверджений практиками

  -- повні дані
  answers         jsonb not null,
  scores          jsonb,
  version         text
);

-- Догляд за базою, розгорнутою до версії 3.2 анкети.
alter table public.responses add column if not exists coverage_scope  text;
alter table public.responses add column if not exists ai_awareness    text;
alter table public.responses add column if not exists confidence      smallint;
alter table public.responses add column if not exists unknown_share   numeric(4,2);
alter table public.responses add column if not exists policy_known    boolean;
alter table public.responses add column if not exists claim_supported boolean;

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
  round(avg(confidence), 0)                  as confidence,
  round(avg(unknown_share), 2)               as unknown_share,
  round(100.0 * count(*) filter (where policy_known is false)
        / nullif(count(*) filter (where policy_known is not null), 0), 0)
                                             as pct_policy_unaware,
  count(*) filter (where claim_supported is false) as claims_unsupported,
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
-- Розрив у сприйнятті: керівництво проти виконавців у межах однієї компанії.
-- Центральний показник дослідження: якщо керівники бачать зрілість вищою,
-- ніж команда, це і є розрив між усвідомленням і фактичною практикою.
-- Alignment: 100 балів мінус 25 за кожен бал розбіжності (шкала 1–5).
-- -----------------------------------------------------------------------------
drop view if exists public.v_perception_gap;
create view public.v_perception_gap as
with tagged as (
  select
    company_key,
    case when leads = 'Ні' then 'team' else 'leaders' end as grp,
    ps_index, gv_index, ef_index, maturity_now
  from public.responses
  where leads is not null
),
agg as (
  select
    company_key,
    count(*) filter (where grp = 'leaders') as n_leaders,
    count(*) filter (where grp = 'team')    as n_team,
    avg(ps_index)      filter (where grp = 'leaders') as ps_leaders,
    avg(ps_index)      filter (where grp = 'team')    as ps_team,
    avg(gv_index)      filter (where grp = 'leaders') as gv_leaders,
    avg(gv_index)      filter (where grp = 'team')    as gv_team,
    avg(ef_index)      filter (where grp = 'leaders') as ef_leaders,
    avg(ef_index)      filter (where grp = 'team')    as ef_team,
    avg(maturity_now)  filter (where grp = 'leaders') as mat_leaders,
    avg(maturity_now)  filter (where grp = 'team')    as mat_team
  from tagged
  group by company_key
)
select
  company_key                                   as company,
  n_leaders, n_team,
  round(ps_leaders, 2)  as ps_leaders,  round(ps_team, 2)  as ps_team,
  round(gv_leaders, 2)  as gv_leaders,  round(gv_team, 2)  as gv_team,
  round(ef_leaders, 2)  as ef_leaders,  round(ef_team, 2)  as ef_team,
  round(mat_leaders, 2) as mat_leaders, round(mat_team, 2) as mat_team,
  round(((ps_leaders - ps_team) + (gv_leaders - gv_team) + (ef_leaders - ef_team)) / 3.0, 2)
                                                as avg_gap,
  greatest(0, round(100 - 25 * abs(
    ((ps_leaders - ps_team) + (gv_leaders - gv_team) + (ef_leaders - ef_team)) / 3.0), 0))
                                                as alignment_score
from agg
where n_leaders >= 2 and n_team >= 3;

comment on view public.v_perception_gap is
  'Розрив у сприйнятті між керівниками й виконавцями. Додатний avg_gap означає, що керівництво оцінює стан вище за команду. Показується лише за наявності щонайменше 2 керівників і 3 виконавців — вимога анонімності.';

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
      execute format('revoke all on public.v_perception_gap     from %I', r);
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
