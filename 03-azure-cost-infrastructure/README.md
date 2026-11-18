# Azure cost and infrastructure

| Script | Purpose |
| --- | --- |
| `azure-total-cost.sh` | Export cost data by subscription and resource |
| `azure-resource-group-cost.sh` | Report costs and resources for one resource group |
| `create-db-jump-vm.sh` | Create a jump VM using an existing VNet/subnet |
| `create-db-jump-vm-from-scratch.sh` | Create a jump VM with a new NSG and public IP |

Cost reports require Azure CLI authentication and `AZURE_SUBSCRIPTION_ID`.
`azure-resource-group-cost.sh` also requires `RESOURCE_GROUP`.

VM creation scripts require the appropriate Azure resource variables; see the
variable names at the top of each file. The first restricts SSH to the current
public IPv4 address, while the second provisions its own network security
group and public IP. Verify networking, access rules, cost, and cleanup plans
before creating infrastructure.
