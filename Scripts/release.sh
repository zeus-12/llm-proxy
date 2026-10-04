#!/usr/bin/env bash
#
# One-command release. Tags the current main commit and pushes the tag; the tag
# push is what triggers CI (.github/workflows/release.yml) to build and publish.
#
#   ./Scripts/release.sh 0.1.1
#
# The git tag is the SINGLE source of truth for the version. There is no manifest
# version to bump — CI derives the version from the tag and passes it to
# Scripts/package-app.sh, which stamps it into the app's Info.plist.
set -euo pipefail

VERSION="${1:-}"
if [[ -z "$VERSION" ]]; then
    echo "usage: $0 <version>   e.g. $0 0.1.1" >&2
    exit 1
fi
if [[ ! "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    echo "error: version must be X.Y.Z (got '$VERSION')" >&2
    exit 1
fi
TAG="v$VERSION"

# 1. Must be on main.
BRANCH="$(git rev-parse --abbrev-ref HEAD)"
if [[ "$BRANCH" != "main" ]]; then
    echo "error: releases must be cut from main (currently on '$BRANCH')" >&2
    exit 1
fi

# 2. Working tree must be clean.
if [[ -n "$(git status --porcelain)" ]]; then
    echo "error: working tree is dirty — commit or stash changes first" >&2
    exit 1
fi

# 3. Tag must not already exist (locally or on the remote).
if git rev-parse --verify --quiet "refs/tags/$TAG" >/dev/null; then
    echo "error: tag $TAG already exists locally" >&2
    exit 1
fi
if git ls-remote --tags --exit-code origin "$TAG" >/dev/null 2>&1; then
    echo "error: tag $TAG already exists on origin" >&2
    exit 1
fi

# 4. Make sure main is pushed, then create and push the tag.
echo "==> Pushing main"
git push origin main

echo "==> Creating tag $TAG"
git tag "$TAG"

echo "==> Pushing tag $TAG (this triggers the release build)"
git push origin "$TAG"

echo
echo "Done. Watch the build: https://github.com/zeus-12/llm-proxy/actions"
