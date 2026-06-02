#!/usr/bin/env python3
"""Render Homepage repository cards from registered app manifests."""

from __future__ import annotations

import re
import sys
from pathlib import Path
from typing import Any

try:
    import yaml
except ImportError:  # pragma: no cover - local fallback for simple app manifests
    yaml = None


ROOT = Path(__file__).resolve().parents[1]
APPS_DIR = ROOT / "apps"
HOMEPAGE_MANIFEST = ROOT / "platform" / "homepage.yaml"
BEGIN = "    # BEGIN GENERATED REPOSITORIES"
END = "    # END GENERATED REPOSITORIES"


def title_from_slug(slug: str) -> str:
    return " ".join(word.upper() if word in {"gh", "usc"} else word.capitalize() for word in slug.split("-"))


def simple_yaml_value(text: str, path: tuple[str, ...]) -> str:
    current_path: list[tuple[int, str]] = []

    for raw_line in text.splitlines():
        if not raw_line.strip() or raw_line.lstrip().startswith("#"):
            continue
        if ":" not in raw_line or raw_line.lstrip().startswith("- "):
            continue

        indent = len(raw_line) - len(raw_line.lstrip(" "))
        key, value = raw_line.strip().split(":", 1)
        value = value.strip().strip("\"'")

        while current_path and indent <= current_path[-1][0]:
            current_path.pop()

        candidate = tuple(item[1] for item in current_path) + (key,)
        if candidate == path:
            return value

        if not value:
            current_path.append((indent, key))

    return ""


def load_app(path: Path) -> dict[str, Any]:
    text = path.read_text(encoding="utf-8")
    if yaml:
        return yaml.safe_load(text) or {}

    return {
        "name": simple_yaml_value(text, ("name",)),
        "image": {"repository": simple_yaml_value(text, ("image", "repository"))},
        "homepage": {"name": simple_yaml_value(text, ("homepage", "name"))},
    }


def github_url_from_image(image_repository: str) -> str:
    match = re.fullmatch(r"ghcr\.io/([^/]+)/([^/:]+)", image_repository)
    if not match:
        return ""

    owner, repo = match.groups()
    return f"https://github.com/{owner}/{repo}"


def repository_cards() -> list[dict[str, str]]:
    cards: list[dict[str, str]] = []

    for app_file in sorted(APPS_DIR.glob("*.yaml")):
        app = load_app(app_file)
        name = str(app.get("name") or app_file.stem)
        homepage = app.get("homepage") if isinstance(app.get("homepage"), dict) else {}
        image = app.get("image") if isinstance(app.get("image"), dict) else {}
        repo_url = github_url_from_image(str(image.get("repository") or ""))

        if not repo_url:
            print(f"Skipping {app_file}: unsupported image.repository", file=sys.stderr)
            continue

        cards.append(
            {
                "title": str(homepage.get("name") or title_from_slug(name)),
                "slug": name,
                "url": repo_url,
            }
        )

    return cards


def render_section(cards: list[dict[str, str]]) -> str:
    lines = [BEGIN, "    - Repositories:"]

    for card in cards:
        lines.extend(
            [
                f"        - {card['title']}:",
                f"            href: {card['url']}",
                f"            siteMonitor: {card['url']}",
                f"            description: Source repository for {card['slug']}",
                "            icon: github.png",
            ]
        )

    lines.append(END)
    return "\n".join(lines)


def main() -> int:
    manifest = HOMEPAGE_MANIFEST.read_text(encoding="utf-8")
    start = manifest.find(BEGIN)
    end = manifest.find(END)

    if start == -1 or end == -1 or end < start:
        print(f"Generated repository markers not found in {HOMEPAGE_MANIFEST}", file=sys.stderr)
        return 1

    end += len(END)
    rendered = render_section(repository_cards())
    HOMEPAGE_MANIFEST.write_text(manifest[:start] + rendered + manifest[end:], encoding="utf-8")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
