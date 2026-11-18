# Residency verification

`verify-residency.sh` creates a read-only Azure inventory summary grouped by
location and resource type. It deliberately omits resource and account
identifiers. Set `ALLOWED_LOCATIONS` to a space-separated allowlist and
optionally `AZURE_SUBSCRIPTION_ID`.

`collect-residency-evidence.sh` gathers detailed Azure evidence and can
optionally inventory AWS. Its output includes live resource identifiers and
account metadata. Treat the generated directory as confidential, review it
before sharing, and do not commit it. The repository ignore rules exclude its
default output directory.
