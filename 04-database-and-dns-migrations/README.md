# Database and DNS migrations

`refresh-test-database.sh` refreshes a test database from a source database. It
requires explicit source and destination hosts, database names, users, and
resource groups. When data crosses regions, it requires a masking script and a
zero-result masking check. It refuses to run unless its Azure VM location can
be verified using `IMDS_LOCATION_URL`. Read the full script before use: the
destination database is dropped and recreated.

`migrate-subdomains.sh` coordinates a Route 53 to Azure App Service migration.
Set the Azure resource group, app names, hosted-zone ID, apex domain, expected
current DNS targets, and load-balancer hosted-zone ID through environment
variables. It asks for an explicit cutover confirmation, but still changes
production DNS; verify all inputs and backups first.
