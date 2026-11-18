# Docker and CI/CD entrypoints

The entrypoint variants construct Spring datasource URLs from injected
`DATABASE_*` variables when `SPRING_DATASOURCE_URL` is unset.

- `entrypoint-spring-datasource.sh` uses the configurable JDBC scheme.
- `entrypoint-spring-datasource-legacy.sh` preserves a permissive legacy form.
- `entrypoint-mariadb-ssl.sh` adds a configurable MariaDB SSL toggle.

Provide `DATABASE_NAME` and `DATABASE_HOST` where applicable. These scripts do
not contain credentials; inject database usernames and passwords through the
deployment platform's secret mechanism.
