# Cloudflare Access Terraform

This Terraform stack creates one Cloudflare Zero Trust Access Application for each app YAML mirrored into `apps/*.yaml` where Access is enabled.

The GitHub Actions workflow copies root-level `../../apps/*.yaml` into this
directory before running Terraform so HCP Terraform receives the app
definitions with the rest of the configuration.

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
Account -> Access: Organizations, Identity Providers, and Groups -> Edit
Account -> Access: Organizations, Identity Providers, and Groups -> Read
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
allowed_idp_ids or managed Google identity provider variables
```

### Existing Google Login Method

To reuse an existing Google login method from Cloudflare Zero Trust, set
`allowed_idp_ids` to the login method ID:

```hcl
allowed_idp_ids = ["<google idp id>"]
```

### Terraform-Managed Google Login Method

To let Terraform create the Cloudflare Zero Trust Google login method, set:

```hcl
allowed_idp_ids                  = []
manage_google_identity_provider  = true
google_identity_provider_type    = "google"
google_oauth_client_id           = "<google oauth client id>"
google_oauth_client_secret       = "<google oauth client secret>"
```

For Google Workspace, use:

```hcl
google_identity_provider_type = "google-apps"
google_workspace_domain       = "example.com"
```

The Google OAuth client still has to exist in Google Cloud. Add Cloudflare's
Access callback URL as an authorized redirect URI in that Google OAuth client.

For GitHub Actions, set one repository secret so the workflow can start Terraform
Cloud runs:

```text
TF_API_TOKEN=<Terraform Cloud token>
```

Set the Cloudflare values as Terraform Cloud workspace variables for the
`cloudflare-access` workspace:

```text
cloudflare_account_id=<account id>
CLOUDFLARE_API_TOKEN=<token with Access Apps and Policies edit access>
```

Then choose one identity provider mode:

```text
allowed_idp_ids=["<google idp id>"]
```

or:

```text
allowed_idp_ids=[]
manage_google_identity_provider=true
google_identity_provider_type=google
google_oauth_client_id=<google oauth client id>
google_oauth_client_secret=<sensitive google oauth client secret>
```

## Run

```bash
rm -rf apps
mkdir -p apps
cp ../../apps/*.yaml apps/
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

The GitHub Actions workflow in `.github/workflows/cloudflare-access.yaml` starts a
Terraform Cloud run whenever app YAML or Cloudflare Access Terraform changes on
`main`.

Before using automatic applies, configure persistent Terraform state in
`versions.tf`, for example Terraform Cloud. Do not run automatic applies with
throwaway local state.
