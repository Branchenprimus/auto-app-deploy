# Agent Instructions

This repository is a single-container web app managed by the Auto App Deploy workflow.

## Philosophy

Keep the app repository small, explicit, and release-driven. The app owns its source code,
Dockerfile, app metadata, and release workflow. The platform repository owns cluster
deployment mechanics through GitOps.

Agents working here should prefer boring, observable changes:

- keep the app runnable through Docker
- keep the container listening on the port declared in app.yaml
- keep app.yaml aligned with the Dockerfile
- release by pushing a version tag, not by editing cluster resources directly
- do not commit secrets, generated caches, local databases, or machine-specific files
- make small commits with behavior-focused messages

## Deployment Contract

The deployment pipeline expects these files:

- Dockerfile
- app.yaml
- .github/workflows/release.yaml

app.yaml is the source of truth for:

- app name
- GHCR image repository
- container HTTP port
- public hostname and path
- Cloudflare Access setting
- resource requests and limits
- environment variables

The Dockerfile must expose and run the same HTTP port as app.yaml:

```yaml
container:
  port: {{CONTAINER_PORT}}
```

If the app changes its runtime port, update both Dockerfile and app.yaml in the same
change. A mismatch can produce Cloudflare 502 errors because Traefik will route to
the wrong container port.

## Release Flow

Releases are tag-based:

```sh
git tag v1.0.0
git push origin v1.0.0
```

The release workflow builds the image, pushes it to GHCR, updates the GitOps values in
the platform repository, and lets ArgoCD sync the cluster.

When using the platform helper, run:

```sh
{{PLATFORM_DIR}}/scripts/create-release.sh
```

That script watches GitHub Actions, ArgoCD, and Kubernetes rollout status.

## Local Development

Build the container before release when possible:

```sh
docker build -t {{APP_NAME}}:local .
docker run --rm -p {{CONTAINER_PORT}}:{{CONTAINER_PORT}} {{APP_NAME}}:local
```

Then open:

```text
http://localhost:{{CONTAINER_PORT}}
```

## Agent Guardrails

- Prefer changing app code and app.yaml over touching generated GitOps files.
- Do not edit Kubernetes resources directly for lasting changes.
- Do not change the release workflow unless the deployment contract changes.
- Check app.yaml, Dockerfile, and the release workflow before diagnosing deploy bugs.
- If Cloudflare returns 502, first verify pod readiness, service endpoints, ingress, and
  whether the container is listening on the configured port.
- If ArgoCD is Synced/Healthy but the app is stale, compare the expected image tag in
  app.yaml with the deployment image in Kubernetes.
- Keep responses short and technical. You are working with developers, who know what they are doing. Ask for clarification if something is unclear. 
