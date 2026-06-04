# Homepage Icon Audit

Goal: Homepage app cards should use the same image a browser would use for each app tab: usually a `<link rel="icon" ...>` target, falling back to `/favicon.ico` only when no explicit icon is declared.

Audited from inside the k3s host with `Host: <app>.darwin-labs.org`, bypassing Cloudflare Access so the app responses can be inspected directly.

## Current status

| App | Browser/tab icon status | Homepage manifest status |
| --- | --- | --- |
| training-planner | OK: HTML declares `/favicon.svg`, served as `image/svg+xml` | Uses mirrored browser icon `/icons/training-planner-favicon.svg` |
| triathlon-race-planner | OK: HTML declares `/favicon.svg`, served as `image/svg+xml` | Uses mirrored browser icon `/icons/triathlon-race-planner-favicon.svg` |
| flashcards | Missing: no `<link rel="icon">`; `/favicon.ico` and `/favicon.svg` return 404 | Temporary fallback `/icons/flashcards.svg` |
| simple-notes | Missing: no `<link rel="icon">`; `/favicon.ico` and `/favicon.svg` return 404 | Temporary fallback `/icons/simple-notes.svg` |
| gh-issue-pipeline | Missing/not browser UI: `/` returns JSON 404; no favicon route | Temporary fallback `/icons/github.svg` |
| usc-crawler | Broken: HTML declares `/favicon.svg`, but `/favicon.svg` returns 404 | Temporary fallback `/icons/usc-crawler.svg` |


## User-in-the-loop tasks

### 1. flashcards: add a browser favicon

Repository: `https://github.com/Branchenprimus/flashcards`

Task:
1. Add a small icon asset to the app's static/public assets, preferably `favicon.svg`.
2. Ensure it is served at `https://flashcards.darwin-labs.org/favicon.svg`.
3. Add this to the HTML `<head>`:

```html
<link rel="icon" type="image/svg+xml" href="/favicon.svg">
```

4. Release the app.
5. Copy the released favicon SVG into `platform/homepage.yaml` under the `homepage-icons` ConfigMap, for example as `flashcards-favicon.svg`.
6. Update `apps/flashcards.yaml`:

```yaml
homepage:
  icon: /icons/flashcards-favicon.svg
```

Acceptance check:

```bash
curl -I -H 'Host: flashcards.darwin-labs.org' http://127.0.0.1/favicon.svg
```

Expected: `200` and an image content type, ideally `image/svg+xml`.

### 2. simple-notes: add a browser favicon

Repository: `https://github.com/Branchenprimus/simple-notes`

Task:
1. Add `favicon.svg` to the app's static/public assets.
2. Ensure it is served at `https://simple-notes.darwin-labs.org/favicon.svg`.
3. Add this to the HTML `<head>`:

```html
<link rel="icon" type="image/svg+xml" href="/favicon.svg">
```

4. Release the app.
5. Copy the released favicon SVG into `platform/homepage.yaml` under the `homepage-icons` ConfigMap, for example as `simple-notes-favicon.svg`.
6. Update `apps/simple-notes.yaml`:

```yaml
homepage:
  icon: /icons/simple-notes-favicon.svg
```

Acceptance check:

```bash
curl -I -H 'Host: simple-notes.darwin-labs.org' http://127.0.0.1/favicon.svg
```

Expected: `200` and `image/svg+xml`.

### 3. usc-crawler: ship the favicon that the HTML already references

Repository: `https://github.com/Branchenprimus/usc-crawler`

Task:
1. The deployed HTML already contains:

```html
<link rel="icon" type="image/svg+xml" href="/favicon.svg">
```

2. Add or fix the static asset so `/favicon.svg` is actually served.
3. Release the app.
4. Copy the released favicon SVG into `platform/homepage.yaml` under the `homepage-icons` ConfigMap, for example as `usc-crawler-favicon.svg`.
5. Update `apps/usc-crawler.yaml` from the temporary fallback to:

```yaml
homepage:
  icon: /icons/usc-crawler-favicon.svg
```

Acceptance check:

```bash
curl -I -H 'Host: usc-crawler.darwin-labs.org' http://127.0.0.1/favicon.svg
```

Expected: `200` and `image/svg+xml`.

### 4. gh-issue-pipeline: decide whether it should have a UI favicon

Repository: `https://github.com/Branchenprimus/gh-issue-pipeline`

This app currently behaves like an API/webhook service: `/` returns JSON 404. If it should appear as a Homepage app tile with a browser-derived icon, add a minimal status page at `/` or `/status` and a favicon.

Task option A, keep it as an API service:
- Leave `apps/gh-issue-pipeline.yaml` using `/icons/github.svg`.

Task option B, add a minimal UI/status page:
1. Serve a minimal HTML page at `/` or `/status`.
2. Serve `/favicon.svg`.
3. Add this to the HTML `<head>`:

```html
<link rel="icon" type="image/svg+xml" href="/favicon.svg">
```

4. Release the app.
5. Copy the released favicon SVG into `platform/homepage.yaml` under the `homepage-icons` ConfigMap, for example as `gh-issue-pipeline-favicon.svg`.
6. Update `apps/gh-issue-pipeline.yaml`:

```yaml
homepage:
  icon: /icons/gh-issue-pipeline-favicon.svg
```

Acceptance check:

```bash
curl -I -H 'Host: gh-issue-pipeline.darwin-labs.org' http://127.0.0.1/favicon.svg
```

Expected: `200` and `image/svg+xml`.

## Re-audit command

Run this after releasing any app favicon fix:

```bash
python3 - <<'PY'
import http.client, re
for app in apps:
    host=f'{app}.darwin-labs.org'
    conn=http.client.HTTPConnection('127.0.0.1',80,timeout=10)
    conn.request('GET','/',headers={'Host':host})
    resp=conn.getresponse(); html=resp.read(500000).decode('utf-8','ignore')
    print('\n', host, '/', resp.status, resp.getheader('Content-Type'))
    conn.close()
    for m in re.finditer(r'<link\s+[^>]*>', html, re.I):
        tag=m.group(0)
        if re.search(r'rel=["\'][^"\']*(?:icon|apple-touch-icon|shortcut icon)[^"\']*["\']', tag, re.I):
            print(' ', tag)
    for path in ['/favicon.svg','/favicon.ico','/apple-touch-icon.png']:
        conn=http.client.HTTPConnection('127.0.0.1',80,timeout=10)
        conn.request('GET',path,headers={'Host':host})
        resp=conn.getresponse(); body=resp.read(1024)
        print(' ', path, resp.status, resp.getheader('Content-Type'), 'bytes>=', len(body))
        conn.close()
PY
```
