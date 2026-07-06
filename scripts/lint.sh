#!/usr/bin/env bash
# lint.sh — sanity checks for the herdr skill repo.
# Run from the repo root: ./scripts/lint.sh

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$REPO_ROOT"

err() { echo "LINT FAIL: $*" >&2; exit 1; }
ok()  { echo "ok: $*"; }

# 1. SKILL.md exists and has frontmatter
[ -f skill/SKILL.md ] || err "skill/SKILL.md is missing"
head -1 skill/SKILL.md | grep -q '^---$' || err "skill/SKILL.md must start with YAML frontmatter (---)"
ok "skill/SKILL.md exists and starts with frontmatter"

# 2. Required frontmatter keys
for key in name description; do
  grep -q "^${key}:" skill/SKILL.md || err "skill/SKILL.md frontmatter missing required key: $key"
done
ok "frontmatter has name + description"

# 3. name field matches the folder convention
NAME=$(awk '/^---$/{c++; next} c==1 && /^name:/{print $2}' skill/SKILL.md | tr -d '"' | tr -d "'")
[ "$NAME" = "herdr" ] || err "frontmatter name is '$NAME', expected 'herdr'"
ok "frontmatter name == herdr"

# 4. reference.md exists (optional but recommended)
if [ -f skill/reference.md ]; then
  ok "skill/reference.md present"
else
  echo "warn: skill/reference.md is missing (recommended)"
fi

# 5. version field, if present, looks like semver
if grep -q '^version:' skill/SKILL.md; then
  VER=$(awk '/^---$/{c++; next} c==1 && /^version:/{print $2}' skill/SKILL.md | tr -d '"' | tr -d "'")
  if ! echo "$VER" | grep -qE '^[0-9]+\.[0-9]+\.[0-9]+$'; then
    err "version '$VER' is not valid semver (X.Y.Z)"
  fi
  ok "version field is valid semver: $VER"
  # If CHANGELOG exists, the most recent version header should match
  if [ -f CHANGELOG.md ]; then
    LATEST=$(grep -E '^## \[[0-9]+\.[0-9]+\.[0-9]+\]' CHANGELOG.md | head -1 | sed -E 's/^## \[([^]]+)\].*/\1/' || true)
    if [ -z "$LATEST" ]; then
      err "CHANGELOG.md has no '## [x.y.z]' version header — add one (latest release first) matching skill version $VER"
    fi
    if [ "$LATEST" != "$VER" ]; then
      err "CHANGELOG.md latest version is [$LATEST] but skill frontmatter says [$VER] — bump one to match"
    fi
    ok "CHANGELOG.md latest version matches skill version"
  fi
else
  echo "warn: no version field in frontmatter (consider adding one)"
fi

# 6. No broken relative .md links in SKILL.md
#    (looks for [text](./path.md) and checks the file exists)
BROKEN=$(grep -oE '\]\(\./[A-Za-z0-9._/-]+\.md\)' skill/SKILL.md | sed -E 's/.*\(\.\/([^)]+)\).*/\1/' | sort -u || true)
for f in $BROKEN; do
  [ -f "skill/$f" ] || err "broken link in skill/SKILL.md: $f"
done
[ -n "$BROKEN" ] && ok "all relative .md links in skill/SKILL.md resolve"
[ -z "$BROKEN" ] && echo "ok: no relative .md links to check"

# 7. README, CHANGELOG, LICENSE exist
for f in README.md CHANGELOG.md LICENSE; do
  [ -f "$f" ] || err "$f is missing"
done
ok "README.md, CHANGELOG.md, LICENSE all present"

echo
echo "All lint checks passed."
