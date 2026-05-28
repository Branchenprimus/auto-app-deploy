# Auto App Deploy

Self-hosted PaaS building blocks for deploying single-container web apps to a Raspberry Pi 5 with k3s, ArgoCD, Traefik, GHCR, and Cloudflare Tunnel.

The intended release path is:

```text
Git tag -> GitHub Actions -> GHCR image -> GitOps app values -> ArgoCD sync -> k3s ingress -> Cloudflare Tunnel
```

## Repository Layout

```text
apps/                         Per-app values consumed by ArgoCD
argocd/                       ArgoCD ApplicationSet
chart/single-container-webapp Generic Helm chart for one HTTP container
app-template/                 Files to copy into application repositories
docs/                         Setup notes for the Raspberry Pi platform
terraform/cloudflare-access/  Cloudflare Zero Trust Access apps generated from apps/*.yaml
platform-access/              Cloudflare Access definitions for platform UIs such as ArgoCD
platform/                     Platform Kubernetes manifests that are not single-container apps
```

## First Deploy Checklist

1. Install k3s on the Raspberry Pi.
2. Confirm Traefik is installed and accepting HTTP traffic on port 80.
3. Configure one Cloudflare Tunnel wildcard route for `*.darwin-labs.org`.
4. Install ArgoCD in the cluster.
5. Create a GitHub repo from this directory and push it.
6. Apply `argocd/applicationset.yaml` after replacing the repository URL.
7. Release a demo app with the workflow in `app-template/.github/workflows/release.yaml`.

## App Contract

Every app repo needs:

- `Dockerfile`
- `app.yaml`
- `.github/workflows/release.yaml`
- a tag release such as `v0.1.0`

See [app-template/app.yaml](/home/jan/projects/auto-app-deploy/app-template/app.yaml) for the expected fields.

New apps should follow [docs/onboard-app.md](/home/jan/projects/auto-app-deploy/docs/onboard-app.md).

Apps that need local runtime storage can enable a PersistentVolumeClaim in
`app.yaml`:

```yaml
persistence:
  enabled: true
  mountPath: /app/data
  size: 2Gi
```

## Cloudflare Access

Apps are protected by Cloudflare Zero Trust Access by default through Terraform.

```yaml
access:
  enabled: true
```

Make an app public with:

```yaml
access:
  enabled: false
```

See [terraform/cloudflare-access/README.md](/home/jan/projects/auto-app-deploy/terraform/cloudflare-access/README.md).

## Platform UIs

Platform UIs are regular Kubernetes manifests under `platform/` and Cloudflare
Access definitions under `platform-access/`.

Expose the ArgoCD web UI with:

```bash
kubectl apply -f platform/argocd-ingress.yaml
```

Cloudflare Access protection for `argocd.darwin-labs.org` is managed from
`platform-access/argocd.yaml`, using the same Google login policy as the app
hostnames.

Expose Homepage with:

```bash
kubectl apply -f platform/homepage.yaml
```

Homepage is available at `https://homepage.darwin-labs.org` after Cloudflare
Access applies `platform-access/homepage.yaml`. Homepage has no built-in auth,
so keep it behind Cloudflare Access.
