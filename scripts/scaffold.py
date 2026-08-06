#!/usr/bin/env python3
"""Generate a new service on the golden path.

Renders templates/service/ into apps/<name>/ and drops an Argo CD Application
into clusters/local/applications/, which is all it takes to onboard a service.

Deliberately dependency-free -- no cookiecutter, no jinja2. A platform tool that
needs a virtualenv before it can run is a platform tool people avoid. `python3
scripts/scaffold.py --help` works on a clean machine and on a CI runner, and
that property is worth more than templating features we don't need.

Usage:
    python3 scripts/scaffold.py --name checkout-api --owner team-checkout \\
        --image ghcr.io/acme/checkout-api:1.4.0 --port 8080 --storage
"""

from __future__ import annotations

import argparse
import re
import shutil
import sys
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parent.parent
TEMPLATE_DIR = REPO_ROOT / "templates" / "service"
APPS_DIR = REPO_ROOT / "apps"
APPLICATIONS_DIR = REPO_ROOT / "clusters" / "local" / "applications"

# Must match the enum in apis/storage/xrd.yaml. Duplicated deliberately: the
# scaffolder should reject a bad region with a clear message rather than let
# the API server reject it later with a schema error the developer can't read.
VALID_REGIONS = ("us-east-1", "us-west-2", "eu-west-1")

# RFC 1123 label. Kubernetes will reject anything else, but it does so at apply
# time with a message about DNS subdomains that means nothing to an app
# developer. Failing here, with an explanation, is the whole point of a
# scaffolder.
NAME_RE = re.compile(r"^[a-z0-9]([-a-z0-9]*[a-z0-9])?$")


class ScaffoldError(Exception):
    """A problem the user can fix, reported without a stack trace."""


def validate(name: str, owner: str, image: str, port: int, region: str) -> None:
    if not NAME_RE.match(name):
        raise ScaffoldError(
            f"invalid service name {name!r}.\n"
            "Must be a valid Kubernetes name: lowercase letters, digits and "
            "hyphens; must start and end with a letter or digit.\n"
            "  good: checkout-api      bad: Checkout_API, -checkout, checkout-"
        )
    if len(name) > 40:
        raise ScaffoldError(
            f"service name is {len(name)} characters; keep it under 40.\n"
            "Kubernetes allows 63, but generated resources append suffixes and "
            "hit that limit in ways that are annoying to debug later."
        )
    if not owner.strip():
        raise ScaffoldError("--owner is required: every service needs a team that owns it")
    if not NAME_RE.match(owner):
        raise ScaffoldError(
            f"invalid owner {owner!r}. Same rules as service names -- it becomes "
            "a Kubernetes label value and an AWS tag."
        )
    if ":" not in image or image.endswith(":latest"):
        raise ScaffoldError(
            f"image {image!r} must carry an explicit, non-'latest' tag.\n"
            "':latest' is not a version -- it makes deploys unreproducible and "
            "rollbacks meaningless."
        )
    if not 1 <= port <= 65535:
        raise ScaffoldError(f"port {port} is outside 1-65535")
    if port < 1024:
        raise ScaffoldError(
            f"port {port} is privileged (<1024). The platform runs containers as "
            "non-root, so the process could not bind it. Use 8080 or similar."
        )
    if region not in VALID_REGIONS:
        raise ScaffoldError(
            f"region {region!r} is not offered. Choose one of: {', '.join(VALID_REGIONS)}"
        )


def check_collisions(name: str) -> None:
    target = APPS_DIR / name
    app_file = APPLICATIONS_DIR / f"{name}.yaml"
    existing = [p for p in (target, app_file) if p.exists()]
    if existing:
        rels = ", ".join(str(p.relative_to(REPO_ROOT)) for p in existing)
        raise ScaffoldError(
            f"service {name!r} already exists ({rels}).\n"
            "Pick a different name, or delete the existing service first. The "
            "scaffolder will not overwrite: silently clobbering someone's "
            "service is worse than making you think about it."
        )


def repo_source() -> tuple[str, str]:
    """Reuse the repoURL/targetRevision the existing Applications already use.

    Reading it from a sibling rather than asking for it keeps the generated
    Application consistent with the rest of the cluster, and means the
    scaffolder works in anyone's fork without configuration.
    """
    for candidate in sorted(APPLICATIONS_DIR.glob("*.yaml")):
        text = candidate.read_text()
        # Skip Helm-chart Applications: their repoURL is a chart repository
        # (charts.crossplane.io), not the Git repo we want to point at.
        if re.search(r"^\s*chart:\s*\S+", text, re.M):
            continue
        url = re.search(r"^\s*repoURL:\s*(\S+)", text, re.M)
        rev = re.search(r"^\s*targetRevision:\s*(\S+)", text, re.M)
        if not (url and rev):
            continue
        if url.group(1).startswith("__"):
            continue  # unresolved placeholder -- 'make init' hasn't run yet
        return url.group(1), rev.group(1)
    raise ScaffoldError(
        "could not determine the repo URL from clusters/local/applications/.\n"
        "Run 'make init' first so the Applications point at your fork."
    )


def render(text: str, values: dict[str, str]) -> str:
    for key, value in values.items():
        text = text.replace("{{" + key + "}}", value)
    leftover = re.findall(r"\{\{([A-Z_]+)\}\}", text)
    if leftover:
        raise ScaffoldError(f"template placeholders were not substituted: {sorted(set(leftover))}")
    return text


def scaffold(name, owner, image, port, region, storage) -> list[Path]:
    validate(name, owner, image, port, region)
    check_collisions(name)
    repo_url, repo_revision = repo_source()

    values = {
        "SERVICE_NAME": name,
        "OWNER": owner,
        "IMAGE": image,
        "PORT": str(port),
        "REGION": region,
        "REPO_URL": repo_url,
        "REPO_REVISION": repo_revision,
    }

    written: list[Path] = []
    target = APPS_DIR / name

    for rel in ("base/deployment.yaml", "base/service.yaml", "base/kustomization.yaml",
                "overlays/local/kustomization.yaml"):
        dest = target / rel
        dest.parent.mkdir(parents=True, exist_ok=True)
        dest.write_text(render((TEMPLATE_DIR / rel).read_text(), values))
        written.append(dest)

    if storage:
        dest = target / "overlays" / "local" / "objectstorage.yaml"
        dest.write_text(render((TEMPLATE_DIR / "objectstorage.yaml").read_text(), values))
        written.append(dest)
        # Wire it into the overlay so Argo CD actually applies it.
        overlay = target / "overlays" / "local" / "kustomization.yaml"
        overlay.write_text(
            overlay.read_text().replace("  - ../../base", "  - ../../base\n  - objectstorage.yaml")
        )

    app = APPLICATIONS_DIR / f"{name}.yaml"
    app.write_text(render((TEMPLATE_DIR / "application.yaml").read_text(), values))
    written.append(app)

    return written


def main() -> int:
    p = argparse.ArgumentParser(
        description="Generate a new service on the golden path.",
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog=__doc__.split("Usage:")[-1],
    )
    p.add_argument("--name", required=True, help="service name, e.g. checkout-api")
    p.add_argument("--owner", required=True, help="owning team, e.g. team-checkout")
    p.add_argument("--image", required=True, help="container image with an explicit tag")
    p.add_argument("--port", type=int, default=8080, help="http port the service listens on")
    p.add_argument("--region", default="us-east-1", choices=VALID_REGIONS,
                   help="AWS region, only used when --storage is set")
    p.add_argument("--storage", action="store_true", help="also request an S3 bucket")
    args = p.parse_args()

    try:
        written = scaffold(args.name, args.owner, args.image, args.port,
                           args.region, args.storage)
    except ScaffoldError as e:
        print(f"\nerror: {e}\n", file=sys.stderr)
        return 1

    print(f"\nScaffolded '{args.name}':\n")
    for path in written:
        print(f"  {path.relative_to(REPO_ROOT)}")
    print(f"""
It already has probes, resource limits, a hardened securityContext and
Prometheus scrape annotations -- none of which anyone had to ask for.

Next:
  git checkout -b scaffold/{args.name}
  git add -A && git commit -m "feat: scaffold {args.name}"
  git push -u origin scaffold/{args.name}

Merging that PR is the deploy. Argo CD picks the Application up from
clusters/local/applications/ and reconciles it.
""")
    return 0


if __name__ == "__main__":
    sys.exit(main())
