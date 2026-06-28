# Tenant & Subscription Troubleshooting

Common issues and solutions when targeting a specific Azure tenant or
subscription with `devclaw up`.

---

## Problem: `devclaw up` uses the wrong tenant or subscription

`azd` (and by extension `devclaw`) picks the tenant and subscription from your
current Azure login session. If you have multiple tenants or subscriptions, it
may default to one you don't intend.

---

## Solutions

### 1. Log in to the correct tenant explicitly

```bash
# Log in to a specific tenant (both az and azd must target the same tenant)
az login --tenant <TENANT_ID>
azd auth login --tenant-id <TENANT_ID>
```

Or use the convenience wrapper:

```bash
./devclaw login          # Unix/macOS
.\devclaw.cmd login      # Windows
```

> **Tip:** Find your tenant ID with `az account list --output table` — the
> `TenantId` column shows the GUID for each subscription.

### 2. Set the subscription before `devclaw up`

```bash
azd env set AZURE_SUBSCRIPTION_ID <SUBSCRIPTION_ID>
```

This pins the subscription for the current azd environment so the interactive
picker is skipped.

> **Tip:** List available subscriptions with `az account list --output table`.

### 3. Switch the default subscription in Azure CLI

```bash
az account set --subscription <SUBSCRIPTION_ID>
```

This changes the default for `az` commands. `azd` may still prompt unless you
also set `AZURE_SUBSCRIPTION_ID` (step 2).

---

## Common error scenarios

| Symptom | Cause | Fix |
|---------|-------|-----|
| `devclaw up` shows subscriptions from a different tenant | `az`/`azd` are logged into the wrong tenant | `az login --tenant <TENANT_ID>` and `azd auth login --tenant-id <TENANT_ID>` |
| Subscription picker doesn't list the target subscription | The subscription belongs to a different tenant than the one you're logged into | Log in to the correct tenant first (see above) |
| `The subscription '<id>' could not be found` | Stale `AZURE_SUBSCRIPTION_ID` in the azd environment pointing to a sub in a different tenant | `azd env set AZURE_SUBSCRIPTION_ID <correct-id>` after logging into the right tenant |
| `Please run 'az login' to setup account` during preprovision hook | `azd` sets `AZURE_CONFIG_DIR` to a repo-local `.azure/` folder that has no signed-in session | Run `az login` in the same shell you run `devclaw up` from; the hook already unsets `AZURE_CONFIG_DIR` as a workaround |
| `AADSTS50020: User account from identity provider does not exist in tenant` | You're trying to use a personal/guest account that isn't in the target tenant | Use an account that is a member of the target tenant, or get a guest invite |
| `Authorization_RequestDenied` creating app registrations | Your account lacks permission to create Entra ID apps in the target tenant | Ask tenant admin for `Application Developer` role, or use a different tenant |
| `ServiceManagementReference field is required for Create` | Restricted tenant requires a service-management-reference GUID on app registrations | `azd env set SERVICE_MANAGEMENT_REFERENCE <guid>` (get the GUID from your tenant admin) |

---

## Full workflow: switching to a new tenant + subscription

```bash
# 1. Log in to the target tenant
az login --tenant <TENANT_ID>
azd auth login --tenant-id <TENANT_ID>

# 2. Confirm you see the right subscription
az account list --output table

# 3. Create a fresh azd environment (or reuse existing)
azd env new <ENV_NAME>

# 4. Pin the subscription and region
azd env set AZURE_SUBSCRIPTION_ID <SUBSCRIPTION_ID>
azd env set AZURE_LOCATION <REGION>

# 5. (Optional) If the target tenant is restricted
azd env set SERVICE_MANAGEMENT_REFERENCE <GUID>   # if required
azd env set SKIP_STORAGE true                     # if shared-key storage is blocked

# 6. Deploy
./devclaw up       # Unix/macOS
.\devclaw.cmd up   # Windows
```

---

## Verifying your current context

```bash
# Show current az CLI tenant + subscription
az account show --output table

# Show current azd environment values
azd env get-values | grep -i "AZURE_SUBSCRIPTION\|AZURE_LOCATION"
```

On Windows PowerShell:

```powershell
az account show --output table
azd env get-values | Select-String "AZURE_SUBSCRIPTION|AZURE_LOCATION"
```

---

## Notes

- `devclaw` is a thin wrapper over `azd`. All `azd env set` variables are
  stored in `.azure/<env-name>/.env` (gitignored) — they are **not** committed.
- If you have separate regions for ACA vs. Azure OpenAI, also set
  `AZURE_OPENAI_LOCATION` (e.g., ACA in `eastasia`, OpenAI in `eastus2`).
- To completely start fresh: `azd env new <name>` creates a clean environment
  with no inherited values.
