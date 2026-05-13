# App Onboarding

Start: Du hast lokal einen eigenen App-Ordner. Das GitHub-Repo kann schon existieren oder vom Script erstellt werden.

## Automatisch

Voraussetzungen:

```text
gh
keepassxc-cli
git
```

Einmalig den zentralen GitOps-Token in KeePassXC speichern:

```bash
/home/jan/projects/auto-app-deploy/scripts/setup-gitops-token-store.sh
```

Standard:

```text
DB:    ~/.config/auto-app-deploy/secrets.kdbx
Entry: GitHub/GITOPS_TOKEN
```

Start:

```bash
/home/jan/projects/auto-app-deploy/scripts/create-new-app.sh
```

Das Script fragt interaktiv nach:

```text
lokalem App-Pfad unter /home/jan/projects
GitHub Owner und Repo
App-Name, Hostname und Port
Cloudflare Access ja/nein
```

Gib z. B. `my-app` ein, um `/home/jan/projects/my-app` zu verwenden. Existiert der Ordner noch nicht, fragt das Script, ob es ihn erstellen soll.

Wenn der Ordner bereits ein Git-Repo mit GitHub-`origin` ist, verwendet das Script diesen Remote als Default, z. B. `Branchenprimus/Flashcards`.

Danach legt es `app.yaml` und den Release-Workflow an, erstellt das GitHub-Repo, setzt `GITOPS_TOKEN` und pusht den Branch.

Beim Lesen des Tokens fragt KeePassXC nach dem Datenbank-Passwort. Die Eingabe ist absichtlich nicht sichtbar.

## Manuell

## 1. App containerfaehig machen

Lege im App-Repo einen `Dockerfile` an.

Pflicht:

```text
ein HTTP-Server
ein bekannter Container-Port
Build muss fuer linux/arm64 funktionieren
```

Lokal testen:

```bash
docker build -t <app-name>:local .
docker run --rm -p 8080:<container-port> <app-name>:local
curl -I http://localhost:8080
```

## 2. `app.yaml` anlegen

Lege im App-Repo `app.yaml` an:

```yaml
name: my-app

image:
  repository: ghcr.io/branchenprimus/my-app

container:
  port: 80

route:
  host: my-app.darwin-labs.org
  path: /

access:
  enabled: true

resources:
  requests:
    cpu: 25m
    memory: 32Mi
  limits:
    cpu: 250m
    memory: 128Mi

env: []
```

Nur wenn die App oeffentlich sein soll:

```yaml
access:
  enabled: false
```

## 3. Release-Workflow kopieren

Im App-Repo:

```bash
mkdir -p .github/workflows
cp /home/jan/projects/auto-app-deploy/app-template/.github/workflows/release.yaml .github/workflows/release.yaml
```

Pruefe in `.github/workflows/release.yaml`:

```yaml
GITOPS_REPO: Branchenprimus/auto-app-deploy
GITOPS_BRANCH: main
```

## 4. GitHub Secret setzen

Einmal pro App-Repo:

```bash
gh secret set GITOPS_TOKEN --repo Branchenprimus/<app-repo>
```

Token einfuegen, wenn `gh` danach fragt.

Der Token braucht Schreibzugriff auf:

```text
Branchenprimus/auto-app-deploy
Contents: Write
```

## 5. App committen und pushen

```bash
git add Dockerfile app.yaml .github/workflows/release.yaml
git commit -m "Add container release workflow"
git push origin <branch>
```

## 6. Release ausloesen

```bash
git tag v0.1.0
git push origin v0.1.0
```

Workflow pruefen:

```bash
gh run list --repo Branchenprimus/<app-repo> --limit 3
gh run watch --repo Branchenprimus/<app-repo>
```

## 7. Deployment pruefen

Nach erfolgreichem Workflow:

```bash
cd /home/jan/projects/auto-app-deploy
git pull
cat apps/my-app.yaml
```

Auf dem Pi:

```bash
kubectl get applications -n argocd
kubectl get pods -n apps
kubectl get ingress -n apps
```

Lokaler Ingress-Test:

```bash
curl -I -H "Host: my-app.darwin-labs.org" http://localhost
```

Public Test:

```bash
curl -I https://my-app.darwin-labs.org
```

Erwartung:

```text
access.enabled: true  -> 302 zu Cloudflare Access Login
access.enabled: false -> 200/3xx direkt von der App
```

## 8. Spaetere Releases

Code aendern, committen, pushen, neuen Tag setzen:

```bash
git tag v0.1.1
git push origin v0.1.1
```

Keine manuellen Kubernetes- oder Cloudflare-Aenderungen noetig.
