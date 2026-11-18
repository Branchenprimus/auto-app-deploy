# Homepage icons: local, independent of app authentication

All Homepage tile icons are served from Homepage itself at `/icons/*.png`.
They must not load from an app's authenticated hostname, a favicon endpoint that
may return SPA HTML, a CDN, or a third-party icon server at browser runtime.

- Source PNGs: `platform/homepage-icons/` (128 × 128 transparent assets).
- Provenance and application/service mapping: `platform/homepage-icons/sources.yaml`.
- Generated app registry: `chart/single-container-webapp/files/homepage-icons.yaml`.
- Generated mounted asset ConfigMap: `homepage-icons` in `platform/homepage.yaml`.
- Manual cards are updated in place, preserving repository-generation markers.

The chart resolves known application names through the checked-in registry.
Unregistered applications get `/icons/app-default.png`, never a guessed remote
`/favicon.ico`. The legacy `homepage.icon` app field is no longer emitted. This
prevents an old app manifest/release from restoring an unreliable remote URL.

Some API-only apps do not publish a favicon. Those use explicitly recorded
meaningful local fallbacks; a real browser-tab icon is preferred when available.
Nextcloud publishes its real icon at `/core/img/favicon.ico`, not `/favicon.ico`.

## Add or replace an icon

1. Obtain the actual advertised `rel=icon`/`apple-touch-icon` from the app. When
   Cloudflare Access protects it, retrieve the image through the authorized
   internal ingress with the correct Host header. Reject HTML or login pages
   even when the HTTP status is 200.
2. Decode it as an image, rasterize SVG to a self-contained PNG, and place the
   resulting 128 × 128 transparent asset under `platform/homepage-icons/`.
   Never check in credentials or remote SVGs with executable/external content.
3. Update `sources.yaml` with the filename, original source, fallback status and
   SHA-256, plus its app name or manual-service name mapping.
4. Run:

   ```sh
   python scripts/render-homepage-icons.py
   python -m unittest discover -s scripts -p 'test_homepage_icons.py' -v
   ```

5. Commit the assets and generated changes together and push to `main`. The
   Argo CD application `homepage` (`platform/homepage-application.yaml`) syncs
   `platform/homepage.yaml` with server-side apply. The renderer stores a
   checksum of both Homepage ConfigMaps on the Deployment pod template, so a
   config or icon change rolls out a fresh Homepage pod; no manual
   `kubectl apply` or restart is needed. CI fails when the checksum is stale.

Each tile shows at most one status dot. `siteMonitor` checks the app's
in-cluster Service (`http://<name>.<namespace>.svc.cluster.local/`), not the
public URL, because Cloudflare Access answers that even when the app is down.
Chart apps set `gethomepage.dev/external: "true"` to hide Homepage's second,
Kubernetes pod-status dot. Stopped apps (`replicaCount: 0`) keep their tile;
the check is refused and the dot turns red. GitHub, GHCR and Cloudflare cards
are plain links without a dot. Adminer accepts no in-cluster traffic
(NetworkPolicy), so its tile uses the Kubernetes pod status instead. Regenerate repository cards with
`python scripts/render-homepage-repositories.py`.

Repository-card generation already emits `/icons/github.png`, including newly
found repositories, and local-icon regeneration preserves those new cards.

## Acceptance check

Use a fresh Chromium context and load Homepage through internal ingress, leaving
public Cloudflare Access enabled. Scroll through every card to exercise lazy
loading. Compare the card links with the pre-change inventory, verify every image
has `naturalWidth > 0`, and assert every tile image URL is same-origin. Repeat at
a phone viewport and after reload. Block off-origin image requests during the
check: all icons must still render. A successful curl alone does not prove that
the actual browser image decoded correctly.

`Homepage icon regression checks` in GitHub Actions validates rendered annotations,
manual cards, checked-in PNGs, size limits and deterministic ConfigMap generation.
