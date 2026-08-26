-- =============================================================================
-- pgvector: семантичний аналіз відкритих відповідей (питання 44 і 45)
-- Виконувати ПІСЛЯ db/schema.sql.
-- Потребує розширення vector (у Supabase доступне; у власному Postgres —
-- встановити pgvector: brew install pgvector / apt install postgresql-17-pgvector).
-- =============================================================================

create extension if not exists vector;

-- -----------------------------------------------------------------------------
-- Ембединги відкритих відповідей.
-- Розмірність 1536 — під text-embedding-3-small (OpenAI) та voyage-3-lite.
-- Змінюючи модель, змініть і розмірність: типи vector(n) несумісні між собою.
-- -----------------------------------------------------------------------------
create table if not exists public.answer_embeddings (
  id           uuid primary key default gen_random_uuid(),
  response_id  uuid not null references public.responses(id) on delete cascade,
  field        text not null check (field in ('story', 'wish')),
  content      text not null,
  embedding    vector(1536),
  model        text,
  created_at   timestamptz not null default now(),
  unique (response_id, field)
);

comment on table public.answer_embeddings is
  'Ембединги відповідей на питання 44 (кейс) і 45 (одна зміна). Заповнюється окремим скриптом, не з браузера.';

-- HNSW за косинусною відстанню: швидкий пошук найближчих сусідів.
create index if not exists answer_embeddings_hnsw
  on public.answer_embeddings using hnsw (embedding vector_cosine_ops);

create index if not exists answer_embeddings_field_idx
  on public.answer_embeddings (field);

-- -----------------------------------------------------------------------------
-- Доступ: анонімний ключ не має до цієї таблиці жодного стосунку.
-- Ембединги створює бекенд-скрипт під власником бази.
-- -----------------------------------------------------------------------------
alter table public.answer_embeddings enable row level security;

do $$
declare r text;
begin
  foreach r in array array['anon','authenticated'] loop
    if exists (select 1 from pg_roles where rolname = r) then
      execute format('revoke all on public.answer_embeddings from %I', r);
    end if;
  end loop;
end $$;

-- -----------------------------------------------------------------------------
-- Пошук схожих відповідей: «покажи все, що близьке за змістом до цієї думки».
-- Приклад: знайти висловлювання про страх помилки.
--   select * from public.similar_answers(
--     (select embedding from public.answer_embeddings limit 1), 'wish', 10);
-- -----------------------------------------------------------------------------
create or replace function public.similar_answers(
  query_embedding vector(1536),
  in_field        text default null,
  limit_n         integer default 10
)
returns table (
  response_id uuid,
  field       text,
  content     text,
  similarity  numeric
)
language sql
stable
as $$
  select
    e.response_id,
    e.field,
    e.content,
    round((1 - (e.embedding <=> query_embedding))::numeric, 4) as similarity
  from public.answer_embeddings e
  where e.embedding is not null
    and (in_field is null or e.field = in_field)
  order by e.embedding <=> query_embedding
  limit limit_n;
$$;

-- -----------------------------------------------------------------------------
-- Відкриті відповіді, які ще не мають ембединга — вхід для скрипта.
-- -----------------------------------------------------------------------------
create or replace view public.v_pending_embeddings as
select r.id as response_id, 'story' as field, r.answers ->> 'story' as content
from public.responses r
where coalesce(trim(r.answers ->> 'story'), '') <> ''
  and not exists (select 1 from public.answer_embeddings e
                  where e.response_id = r.id and e.field = 'story')
union all
select r.id, 'wish', r.answers ->> 'wish'
from public.responses r
where coalesce(trim(r.answers ->> 'wish'), '') <> ''
  and not exists (select 1 from public.answer_embeddings e
                  where e.response_id = r.id and e.field = 'wish');

do $$
declare r text;
begin
  foreach r in array array['anon','authenticated'] loop
    if exists (select 1 from pg_roles where rolname = r) then
      execute format('revoke all on public.v_pending_embeddings from %I', r);
    end if;
  end loop;
end $$;
