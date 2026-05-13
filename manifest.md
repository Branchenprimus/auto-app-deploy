Ziel ist eine kleine eigene **Self-Hosted PaaS auf dem Raspberry Pi 5**: Ein Developer baut eine Web-App als Container, tagged ein Release in GitHub, und die App wird automatisch über eine Domain veröffentlicht.

## Ziel-Flow

```text
Developer entwickelt App lokal
  ↓
Push nach GitHub
  ↓
Git Tag, z. B. v0.1.0
  ↓
GitHub Action baut Docker Image
  ↓
Image wird nach GHCR gepusht
  ↓
GitHub Action aktualisiert GitOps Repo
  ↓
ArgoCD erkennt Änderung
  ↓
ArgoCD deployed nach k3s
  ↓
Cloudflare Tunnel routet Traffic auf k3s Ingress
  ↓
App ist öffentlich erreichbar
```

Beispiel-URL:

```text
https://flashcards.darwin-labs.org
```

Optional später zusätzlich:

```text
https://darwin-labs.org/apps/flashcards
```

Für den Anfang sind **Subdomains klar robuster** als `/apps/<app-name>`, weil beliebige Web-Apps oft Probleme mit Subpaths, Assets, Redirects, Cookies, WebSockets oder API-Routen bekommen.

## Architektur

```text
GitHub App Repo
  ├── Source Code
  ├── Dockerfile
  ├── app.yaml
  └── GitHub Actions Workflow

GitHub Container Registry
  └── ghcr.io/<owner>/<app>:<tag>

GitOps Repo
  ├── apps/
  │   ├── flashcards.yaml
  │   ├── training-planner.yaml
  │   └── ...
  ├── chart/
  │   └── single-container-webapp/
  └── argocd/
      └── applicationset.yaml

Raspberry Pi 5
  ├── k3s
  ├── Traefik Ingress Controller
  ├── ArgoCD
  └── Cloudflare Tunnel
```

## App-Typ

Es wird nur **Typ 2** unterstützt:

```text
Single Container Web App
```

Das heißt: Jede Anwendung ist ein Container, der HTTP auf einem bekannten Port spricht.

Beispiele:

```text
Node.js / Express
Vue/Nuxt mit eigenem Server
FastAPI
Flask
Streamlit
Go Webserver
Spring Boot
beliebiger HTTP-Container
```

Nicht Teil des ersten Scopes:

```text
Datenbanken
PVCs
Multi-Container-Stacks
StatefulSets
komplexe Helm-Charts pro App
```

Diese Dinge können später ergänzt werden.

## Standard-App-Contract

Jede App muss nur einen kleinen Contract erfüllen:

```text
1. Es gibt ein Dockerfile
2. Die App läuft als einzelner Container
3. Die App hört auf einem bekannten HTTP-Port
4. Der Port steht in app.yaml
5. Ein Git Tag löst den Release aus
```

Beispiel `app.yaml` im App-Repo:

```yaml
name: flashcards

image:
  repository: ghcr.io/branchenprimus/flashcards

container:
  port: 3000

route:
  host: flashcards.darwin-labs.org

resources:
  requests:
    cpu: 50m
    memory: 64Mi
  limits:
    cpu: 500m
    memory: 512Mi

env:
  - name: NODE_ENV
    value: production
```

Beim Release ergänzt die GitHub Action den Tag:

```yaml
image:
  repository: ghcr.io/branchenprimus/flashcards
  tag: v0.1.0
```

## GitOps-Prinzip

GitHub Actions sollen **nicht direkt per SSH oder kubectl auf den Raspberry Pi zugreifen**.

Nicht ideal:

```text
GitHub Action → SSH auf Pi → kubectl apply
```

Stattdessen:

```text
GitHub Action → GitOps Repo ändern → ArgoCD deployed
```

Vorteile:

```text
Git ist Single Source of Truth
Deployments sind nachvollziehbar
Rollback ist einfach
ArgoCD kann Self-Healing machen
kein direkter Cluster-Zugriff aus GitHub Actions nötig
```

## GitOps Repo

Beispielstruktur:

```text
pi-gitops/
├── apps/
│   ├── flashcards.yaml
│   ├── training-planner.yaml
│   └── kcal-tracker.yaml
├── chart/
│   └── single-container-webapp/
│       ├── Chart.yaml
│       ├── values.yaml
│       └── templates/
│           ├── deployment.yaml
│           ├── service.yaml
│           └── ingress.yaml
└── argocd/
    └── applicationset.yaml
```

Jede Datei unter `apps/` beschreibt eine App:

```yaml
name: flashcards
namespace: apps

image:
  repository: ghcr.io/branchenprimus/flashcards
  tag: v0.1.0

container:
  port: 3000

route:
  host: flashcards.darwin-labs.org
  path: /

resources:
  requests:
    cpu: 50m
    memory: 64Mi
  limits:
    cpu: 500m
    memory: 512Mi
```

## ArgoCD-Modell

Empfohlen ist ein **ApplicationSet**.

Das ApplicationSet liest alle Dateien aus:

```text
apps/*.yaml
```

und erzeugt pro Datei automatisch eine eigene ArgoCD Application.

Vorteile:

```text
jede App ist in ArgoCD separat sichtbar
jede App kann separat synchronisiert werden
Fehler sind pro App isoliert
neue App = neue YAML-Datei
```

ArgoCD rendert dann den generischen Helm Chart `single-container-webapp` mit den Werten aus der jeweiligen App-YAML.

## Generischer Helm Chart

Der Helm Chart erzeugt für jede App:

```text
Deployment
Service
Ingress
```

Optional später:

```text
ConfigMap
Secret
PVC
HPA
NetworkPolicy
```

Für den Anfang reichen Deployment, Service und Ingress.

Der Chart ist für alle Apps gleich. Die Unterschiede kommen nur über Values.

## GitHub Action pro App

Der Release-Workflow läuft bei Tags:

```yaml
on:
  push:
    tags:
      - "v*"
```

Die Action macht:

```text
1. Repository auschecken
2. Docker Image bauen
3. Image nach GHCR pushen
4. app.yaml lesen
5. GitOps Repo auschecken
6. apps/<app-name>.yaml erstellen oder aktualisieren
7. image.tag auf Git Tag setzen
8. Commit und Push ins GitOps Repo
```

Danach macht ArgoCD automatisch den Rest.

## Cloudflare-Design

Cloudflare sollte nicht pro App geändert werden müssen.

Nicht ideal:

```text
jede App einzeln in cloudflared config eintragen
flashcards.darwin-labs.org → localhost:3001
training-planner.darwin-labs.org → localhost:3002
...
```

Besser:

```text
Cloudflare Tunnel → k3s Ingress Controller → Kubernetes Services
```

Einmalige Tunnel-Konfiguration:

```yaml
ingress:
  - hostname: "*.darwin-labs.org"
    service: http://localhost:80

  - hostname: "darwin-labs.org"
    service: http://localhost:80

  - service: http_status:404
```

Dann entscheidet Kubernetes Ingress, welche App wohin geht.

Beispiel:

```yaml
route:
  host: flashcards.darwin-labs.org
```

wird zu einem Kubernetes Ingress für:

```text
flashcards.darwin-labs.org
```

Cloudflare bleibt unverändert.

## Cloudflare Access

Cloudflare Access Applications brauchst du nur, wenn einzelne Apps geschützt werden sollen.

Beispiele:

```text
public-app.darwin-labs.org       öffentlich
admin-app.darwin-labs.org        nur du
client-demo.darwin-labs.org      nur bestimmte E-Mail-Adressen
```

Das kann man automatisieren, aber eher mit:

```text
Terraform
Cloudflare API
```

Nicht primär mit `cloudflared`.

Für die erste Version der Plattform:

```text
keine neue Cloudflare Access Application pro App
einmal Wildcard Tunnel
Routing über Kubernetes Ingress
```

## Veröffentlichungsprozess aus Developer-Sicht

Ein Developer erstellt eine App mit:

```text
Dockerfile
app.yaml
GitHub Action
```

Dann:

```bash
git add .
git commit -m "Initial release"
git push

git tag v0.1.0
git push origin v0.1.0
```

Danach passiert automatisch:

```text
Image wird gebaut
Image wird gepusht
GitOps Repo wird aktualisiert
ArgoCD deployed
App ist unter der Subdomain erreichbar
```

Beispiel:

```text
https://flashcards.darwin-labs.org
```

## Rollback

Rollback ist einfach:

```text
apps/flashcards.yaml image.tag von v0.1.1 zurück auf v0.1.0 setzen
Commit ins GitOps Repo
ArgoCD synced
```

Oder über Git revert im GitOps Repo.

## Warum diese Architektur gut passt

Sie erfüllt die Kernziele:

```text
schnelle Veröffentlichung
wenig manuelle Arbeit
keine SSH-Deployments
keine Cloudflare-Änderung pro App
jede App isoliert sichtbar
GitOps-konform
gut rollbackbar
erweiterbar
```

## MVP-Scope

Der erste umsetzbare MVP sollte sein:

```text
1. k3s läuft auf Raspberry Pi
2. Traefik Ingress läuft
3. Cloudflare Wildcard Tunnel zeigt auf Traefik
4. ArgoCD läuft
5. GitOps Repo existiert
6. ApplicationSet liest apps/*.yaml
7. Generischer Helm Chart deployed Single-Container-Webapps
8. Demo-App wird über GitHub Tag released
9. App ist unter demo.darwin-labs.org erreichbar
```

Danach kann man erweitern um:

```text
App-Template-Repo
automatische App-Registry
Portal unter darwin-labs.org/apps
Cloudflare Access per Terraform
Secrets Management
Persistenz
Monitoring
Logs
Backups
```

## Kurzfassung

Das System sollte so gebaut werden:

```text
GitHub Tag
  → GitHub Action baut Container
  → Push nach GHCR
  → GitOps Repo wird geändert
  → ArgoCD deployed nach k3s
  → Traefik routet anhand der Subdomain
  → Cloudflare Tunnel macht die App öffentlich erreichbar
```

Die Cloudflare-Konfiguration sollte möglichst statisch bleiben. Neue Apps entstehen nur durch neue YAML-Dateien im GitOps Repo.

