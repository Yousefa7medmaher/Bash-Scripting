#!/bin/sh
set -eu

if [ -z "${SPRING_DATASOURCE_URL:-}" ] && [ -n "${DATABASE_HOST:-}" ]; then
  case "${DB_SSL:-false}" in
    true|TRUE|1) SSL=true ;;
    *) SSL=false ;;
  esac
  : "${DATABASE_NAME:?DATABASE_NAME is required}"
  SPRING_DATASOURCE_URL="jdbc:mariadb://${DATABASE_HOST}:${DATABASE_PORT:-3306}/${DATABASE_NAME}?useUnicode=true&characterEncoding=utf8&useSSL=${SSL}&allowPublicKeyRetrieval=true"
  export SPRING_DATASOURCE_URL
  echo "entrypoint: datasource URL built from DATABASE_* variables (host=$DATABASE_HOST)"
fi

exec "$@"
