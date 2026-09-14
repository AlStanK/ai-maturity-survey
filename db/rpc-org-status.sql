-- =============================================================================
-- Безпечна RPC-функція перевірки статусу та кількості відповідей за кодом організації
-- Дозволяє координаторам перевіряти прогрес збору без розкриття індивідуальних даних.
-- Якщо відповідей < 5: повертає лише лічильник та скільки залишилось до порогу.
-- Якщо відповідей >= 5: повертає розраховані агреговані індекси організації.
-- =============================================================================

create or replace function public.get_org_status(lookup_code text)
returns json
language plpgsql
security definer
stable
as $$
declare
  clean_code text := upper(trim(lookup_code));
  cnt int;
  c_name text;
  c_ind text;
begin
  select count(*), min(company), max(industry)
  into cnt, c_name, c_ind
  from public.responses
  where company_key = lower(clean_code);

  if cnt = 0 then
    return json_build_object(
      'found', false,
      'org_code', clean_code,
      'count', 0,
      'threshold', 5,
      'remaining', 5,
      'ready', false,
      'message', 'За цим кодом відповідей ще немає'
    );
  end if;

  if cnt < 5 then
    return json_build_object(
      'found', true,
      'org_code', clean_code,
      'company_name', c_name,
      'industry', c_ind,
      'count', cnt,
      'threshold', 5,
      'remaining', 5 - cnt,
      'ready', false,
      'message', format('Отримано %s із 5 необхідних відповідей для формування повного індексу', cnt)
    );
  else
    return (
      select json_build_object(
        'found', true,
        'org_code', clean_code,
        'company_name', min(company),
        'industry', max(industry),
        'count', count(*),
        'threshold', 5,
        'remaining', 0,
        'ready', true,
        'ps_index', round(avg(ps_index), 2),
        'gv_index', round(avg(gv_index), 2),
        'ef_index', round(avg(ef_index), 2),
        'maturity_now', round(avg(maturity_now), 1),
        'maturity_target', round(avg(maturity_target), 1),
        'confidence', round(avg(confidence), 0)
      )
      from public.responses
      where company_key = lower(clean_code)
    );
  end if;
end;
$$;

do $$
declare r text;
begin
  foreach r in array array['anon','authenticated','web_anon','anonymous'] loop
    if exists (select 1 from pg_roles where rolname = r) then
      execute format('grant execute on function public.get_org_status(text) to %I', r);
    end if;
  end loop;
end $$;
