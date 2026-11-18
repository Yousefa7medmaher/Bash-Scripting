#!/bin/sh
set -e

# Build the JDBC URL from the variables injected by the deploy component, unless one is already set.
if [ -z "$SPRING_DATASOURCE_URL" ] && [ -n "$DATABASE_HOST" ]; then
  export SPRING_DATASOURCE_URL="jdbc:${DB_JDBC_SCHEME:-mariadb}://${DATABASE_HOST}:${DATABASE_PORT:-3306}/${DATABASE_NAME}"
fi

exec "$@"
