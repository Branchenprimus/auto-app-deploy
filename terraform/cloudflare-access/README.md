# Cloudflare Access Terraform

This Terraform stack creates one Cloudflare Zero Trust Access Application for each app in `../../apps/*.yaml` where Access is enabled.

Access is enabled by default:

```yaml
access:
  enabled: true
```

Opt a public app out with:

```yaml
access:
  enabled: false
```

## Required Cloudflare Token

Create a Cloudflare API token with:

```text
Account -> Access: Apps and Policies -> Edit
Account -> Access: Apps and Policies -> Read
```

Export it locally:

```bash
export CLOUDFLARE_API_TOKEN=...
```

## Configure

Copy the example variables:

```bash
cp terraform.tfvars.example terraform.tfvars
```

Set:

```text
cloudflare_account_id
allowed_idp_ids
```

The `allowed_idp_ids` list should contain your Google login method ID from Cloudflare Zero Trust.

For GitHub Actions, set repository variables:

```text
CLOUDFLARE_ACCOUNT_ID=<account id>
CLOUDFLARE_ALLOWED_IDP_IDS=["<google idp id>"]
TF_AUTO_APPLY_CLOUDFLARE_ACCESS=true
```

and repository secret:

```text
CLOUDFLARE_API_TOKEN=<token with Access Apps and Policies edit access>
```

## Run

```bash
terraform init
terraform plan
terraform apply
```

## Existing Manual Access Apps

If a hostname already has a manually created Cloudflare Access Application, import it before the first apply or remove the manual app from Cloudflare.

Example:

```bash
terraform import \
  'cloudflare_zero_trust_access_application.app["triathlon-race-planner"]' \
  'accounts/<cloudflare_account_id>/<access_application_id>'
```

## Auto Apply

The GitHub Actions workflow in `.github/workflows/cloudflare-access.yaml` is intentionally guarded by `TF_AUTO_APPLY_CLOUDFLARE_ACCESS == "true"`.

Before enabling it, configure persistent Terraform state in `versions.tf`, for example Terraform Cloud. Do not run automatic applies with throwaway local state.
