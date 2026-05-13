# Platform Setup Notes

## k3s

Install k3s on the Raspberry Pi and keep the bundled Traefik ingress controller enabled for the MVP.

```bash
curl -sfL https://get.k3s.io | sh -
```

Check the cluster:

```bash
sudo kubectl get nodes
sudo kubectl get pods --all-namespaces
```

## Cloudflare Tunnel

Use one wildcard tunnel that forwards all app hostnames to Traefik:

```yaml
ingress:
  - hostname: "*.darwin-labs.org"
    service: http://localhost:80
  - hostname: "darwin-labs.org"
    service: http://localhost:80
  - service: http_status:404
```

## ArgoCD

Install ArgoCD, then apply the ApplicationSet from this repo:

```bash
kubectl create namespace argocd
kubectl apply -n argocd -f https://raw.githubusercontent.com/argoproj/argo-cd/stable/manifests/install.yaml
kubectl apply -f argocd/applicationset.yaml
```

Before applying, replace `repoURL` in `argocd/applicationset.yaml` with the real GitOps repository URL.

## GitHub Token

Each app repository needs a `GITOPS_TOKEN` secret with permission to push to the GitOps repository.
