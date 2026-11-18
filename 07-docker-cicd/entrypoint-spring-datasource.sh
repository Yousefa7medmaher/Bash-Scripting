#!/bin/sh
set -eu

# The deploy template injects DATABASE_HOST / DATABASE_PORT / DATABASE_NAME and
# the user/password (renamed to SPRING_DATASOURCE_USERNAME / _PASSWORD in CI).
# Spring needs a single JDBC URL, so build it here unless one is already set.
if [ -z "${SPRING_DATASOURCE_URL:-}" ] && [ -n "${DATABASE_HOST:-}" ]; then
  : "${DATABASE_NAME:?DATABASE_NAME is required}"
  SPRING_DATASOURCE_URL="jdbc:${DB_JDBC_SCHEME:-mysql}://${DATABASE_HOST}:${DATABASE_PORT:-3306}/${DATABASE_NAME}?useUnicode=true&characterEncoding=utf8&useSSL=false&allowPublicKeyRetrieval=true"
  export SPRING_DATASOURCE_URL
fi

exec java -jar application.jar "$@"
