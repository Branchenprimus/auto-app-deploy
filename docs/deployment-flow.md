# Deployment Flow

```mermaid
flowchart TD
  dev["Developer<br/>local app development<br/>/home/jan/projects/&lt;app&gt;"]
  apprepo["App repository<br/>Dockerfile<br/>app.yaml<br/>release workflow"]
  gitops["auto-app-deploy repository<br/>apps/*.yaml<br/>Helm chart<br/>ArgoCD ApplicationSet<br/>Cloudflare Terraform"]
  ghcr["GHCR<br/>ghcr.io/branchenprimus/&lt;app&gt;:&lt;tag&gt;"]
  cluster["Raspberry Pi k3s cluster"]
  argocd["ArgoCD<br/>watches auto-app-deploy main"]
  helm["Helm chart<br/>chart/single-container-webapp"]
  workload["Kubernetes apps namespace<br/>Deployment<br/>Service<br/>Ingress"]
  traefik["Traefik ingress<br/>port 80"]
  tunnel["Cloudflare Tunnel<br/>*.darwin-labs.org to Traefik"]
  access["Cloudflare Zero Trust Access<br/>per-app protected hostnames"]
  google["Google login<br/>Cloudflare IdP"]
  browser["User browser<br/>https://&lt;app&gt;.darwin-labs.org"]

  subgraph local["Local workstation"]
    setupToken["scripts/setup-gitops-token-store.sh<br/>stores GitOps token in KeePassXC"]
    newApp["scripts/create-new-app.sh<br/>creates or prepares app repo<br/>writes app.yaml<br/>copies release workflow<br/>sets issue labels and GitHub secret"]
    releaseScript["scripts/create-release.sh<br/>creates and pushes vX.Y.Z tag<br/>watches GitHub Actions and rollout"]
    ghcrSecret["scripts/setup-ghcr-pull-secret.sh<br/>creates Kubernetes imagePullSecret ghcr-pull"]
    keepass[("KeePassXC database<br/>~/.config/auto-app-deploy/secrets.kdbx")]
  end

  subgraph tokens["Tokens and secrets"]
    gitopsToken[["GITOPS_TOKEN<br/>GitHub token with write access<br/>to auto-app-deploy"]]
    githubToken[["GITHUB_TOKEN<br/>GitHub Actions built-in token<br/>packages:write to GHCR"]]
    ghcrPullToken[["GHCR pull token<br/>classic token with read:packages"]]
    tfToken[["TF_API_TOKEN<br/>Terraform Cloud API token"]]
    cfToken[["CLOUDFLARE_API_TOKEN<br/>Cloudflare Access edit permissions"]]
    googleOAuth[["Google OAuth client<br/>client_id and client_secret<br/>optional Terraform-managed IdP"]]
  end

  subgraph github["GitHub automation"]
    appActions["App repo GitHub Actions<br/>app-template/.github/workflows/release.yaml"]
    cfActions["auto-app-deploy GitHub Actions<br/>.github/workflows/cloudflare-access.yaml"]
    terraformCloud["HCP Terraform workspace<br/>cloudflare-access"]
  end

  dev --> setupToken
  setupToken --> keepass
  gitopsToken --> setupToken
  keepass --> newApp
  dev --> newApp
  newApp --> apprepo
  newApp --> gitopsToken
  gitopsToken --> apprepo
  newApp -->|sets app repo secret| apprepo

  dev --> releaseScript
  releaseScript -->|pushes release tag| apprepo
  apprepo -->|tag vX.Y.Z| appActions
  githubToken --> appActions
  gitopsToken --> appActions
  appActions -->|builds linux/arm64 image| ghcr
  appActions -->|copies app.yaml and sets image.tag| gitops

  gitops -->|main branch changed| argocd
  argocd -->|generates one Application per apps/*.yaml| helm
  helm --> workload
  ghcrPullToken --> ghcrSecret
  ghcrSecret -->|Kubernetes docker-registry secret| cluster
  workload -->|pulls image using ghcr-pull| ghcr
  workload --> cluster
  cluster --> traefik
  traefik --> tunnel

  gitops -->|apps/*.yaml or Terraform changed| cfActions
  tfToken --> cfActions
  cfActions -->|syncs apps/*.yaml into terraform/cloudflare-access/apps| terraformCloud
  cfToken --> terraformCloud
  googleOAuth --> terraformCloud
  terraformCloud -->|creates or updates Access Applications| access
  terraformCloud -->|optionally manages Google IdP| google
  google --> access

  browser --> tunnel
  tunnel --> access
  access -->|authenticated request| traefik
  traefik --> workload

  releaseScript -.->|optional status checks| appActions
  releaseScript -.->|optional kubectl and argocd status| argocd
  releaseScript -.->|optional kubectl rollout status| workload
```

## Notes

- App repositories own source code, `Dockerfile`, `app.yaml`, and the release workflow.
- `auto-app-deploy` owns desired deployment state in `apps/*.yaml`, the shared Helm chart, ArgoCD wiring, and Cloudflare Access Terraform.
- App releases are driven by Git tags. The app workflow builds the image, pushes it to GHCR, and commits the updated app values into `auto-app-deploy`.
- ArgoCD turns `apps/*.yaml` into Kubernetes resources through the shared Helm chart.
- Terraform turns `apps/*.yaml` into Cloudflare Access applications and can either reuse an existing Google IdP ID or manage the Cloudflare Google IdP from Google OAuth credentials.
- Runtime traffic flows through Cloudflare Tunnel, Cloudflare Access, Traefik, and then the Kubernetes service for the app.
