#!/bin/bash
# Ролі для PostgREST. Виконується один раз, при першому старті порожнього тому.
#   web_anon      — роль анонімного відвідувача, лише INSERT
#   authenticator — під нею підключається PostgREST і перемикається на web_anon
set -e

psql -v ON_ERROR_STOP=1 --username "$POSTGRES_USER" --dbname "$POSTGRES_DB" <<-EOSQL
  create role web_anon nologin;
  grant usage on schema public to web_anon;

  create role authenticator noinherit login password '${AUTHENTICATOR_PASSWORD}';
  grant web_anon to authenticator;
EOSQL
