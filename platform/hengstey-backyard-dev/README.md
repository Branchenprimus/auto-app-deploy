# Hengstey Backyard Dev on Pi

URL: https://hengstey-backyard-dev.darwin-labs.org

The dedicated Argo CD Application renders the HBP Helm chart and reads values
from this repository. The existing single-container ApplicationSet is unchanged.
Cloudflare Access uses the platform Google login policy; Cloudflare Tunnel
terminates external TLS and sends HTTP to Traefik.

## Bootstrap

Provision namespace `hengstey-dev`, runtime Secret `hengstey-backyard-secrets`
and registry Secret `ghcr-pull` once using an authenticated cluster connection.
Generate fresh dev-only POSTGRES_PASSWORD, SECRET_KEY, S3_ACCESS_KEY_ID and
S3_SECRET_ACCESS_KEY. DATABASE_URL must match PostgreSQL credentials and point
to `hengstey-backyard-postgres:5432/hengstey`; S3_ENDPOINT_URL must be
`http://hengstey-backyard-minio:9000`, S3_REGION `eu-central-1` and S3_BUCKET
`hengstey-backyard-private`. Leave BREVO_API_KEY empty. Never commit plaintext
credentials. The Pi currently has no Sealed Secrets controller.

Apply `application.yaml` once to register the application with Argo CD. This
registration is outside the existing ApplicationSet. Argo CD deploys all app
resources; do not apply rendered workload manifests manually.

## Releases and operations

1. Develop and test locally, then push HBP code to GitHub.
2. Wait for the multi-architecture container build to succeed.
3. Pin `image.tag` in `values.yaml` to the built commit and push this repository.
4. Argo CD automatically reconciles values. If the Helm chart changes, update
   its pinned revision in `application.yaml` and reapply that registration.
5. Verify Synced/Healthy, migration and bucket initialization jobs, and ingress.

One app replica, PostgreSQL and MinIO each have a 384 MiB memory limit. Each
stateful service starts with a 4 GiB local-path PVC on the Pi SD card. Backups
are disabled until configured. Email is recorded in the database but not sent.
The dev database and photo bucket are independent from production. PVCs and
runtime Secrets must be preserved during application maintenance.
