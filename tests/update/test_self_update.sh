#!/usr/bin/env bash
# m2herd self-update / --auto against a throwaway origin with release tags. Offline: temp HOME,
# local bare repo as origin, the engine is a clone carrying a copy of scripts/m2herd.sh.
set -u
REPO="$(cd "$(dirname "$0")/../.." && pwd)"
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
export HOME="$T/home" GIT_CONFIG_NOSYSTEM=1 GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t
mkdir -p "$HOME"
unset M2HERD_UPDATE_CHANNEL M2HERD_AUTO_UPDATE M2HERD_UPDATE_INTERVAL_HOURS
pass=0 fail=0
check() { if eval "$2"; then pass=$((pass + 1)); else fail=$((fail + 1)); echo "FAIL $1"; fi; }

# origin: v1.0.0 → v1.10.0 → v2.0.0-alpha → untagged main head
git init -q --bare -b main "$T/origin.git"
git clone -q "$T/origin.git" "$T/seed" 2>/dev/null
mkdir -p "$T/seed/scripts" && cp "$REPO/scripts/m2herd.sh" "$T/seed/scripts/m2herd.sh"
commit() { (cd "$T/seed" && echo "$1" > v.txt && git add -A && git commit -qm "$1" && { [ -z "${2:-}" ] || git tag "$2"; }); }
commit one v1.0.0; commit nine v1.9.0; commit ten v1.10.0; commit alpha v2.0.0-alpha; commit head
git -C "$T/seed" tag not-a-release HEAD
git -C "$T/seed" push -q origin main --tags
sha() { git -C "$T/seed" rev-parse "$1^{commit}"; }
engine() { rm -rf "$T/eng"; git clone -q "$T/origin.git" "$T/eng" 2>/dev/null; git -C "$T/eng" checkout -q --detach "$1"; }
m2() { bash "$T/eng/scripts/m2herd.sh" "$@"; }
head_is() { [ "$(git -C "$T/eng" rev-parse HEAD)" = "$(sha "$1")" ]; }
cache() { cat "$HOME/.cache/m2herd/update-status" 2>/dev/null; }

# --check: newest release incl. prerelease, semver order (1.10 > 1.9), nothing moves
engine v1.0.0
out="$(m2 self-update --check)"
check "check names the newest release" 'printf "%s" "$out" | grep -q "behind v2.0.0-alpha"'
check "check writes behind + target" 'cache | grep -qE "^behind 3 [0-9T:-]+Z v2.0.0-alpha$"'
check "check moves nothing" 'head_is v1.0.0'

# update: forward to the newest release tag (not the untagged main head)
m2 self-update >/dev/null
check "update lands on the newest release tag" 'head_is v2.0.0-alpha'
check "cache up-to-date after update" 'cache | grep -q "^up-to-date 0 "'
check "second update is a no-op" 'm2 self-update | grep -q "up-to-date"'

# stable channel skips prereleases
engine v1.0.0
M2HERD_UPDATE_CHANNEL=stable m2 self-update >/dev/null
check "stable channel stops at v1.10.0" 'head_is v1.10.0'
check "bad channel is refused" '! M2HERD_UPDATE_CHANNEL=nightly m2 self-update --check >/dev/null 2>&1'

# the installer's shallow clone (--depth 1) of a main that is ahead of the newest tag: no false "diverged"
rm -rf "$T/eng"; git clone -q --depth 1 "file://$T/origin.git" "$T/eng" 2>/dev/null
out="$(m2 self-update --check)"
check "shallow clone ahead of the newest tag reads up-to-date" 'printf "%s" "$out" | grep -q "up-to-date" && cache | grep -q "^up-to-date "'

# a tag that exists only locally (or was deleted on origin) never counts
engine v1.0.0
git -C "$T/eng" tag v9.0.0 v1.0.0
m2 self-update --check >/dev/null
check "local-only tag is ignored" 'cache | grep -q " v2.0.0-alpha$"'

# never downgrade: an engine ahead of the newest tag stays
engine main
m2 self-update >/dev/null
check "ahead of the newest tag: no downgrade" 'head_is main'

# diverged (local commit on an old release) is refused, untouched
engine v1.0.0
(cd "$T/eng" && echo mine > mine.txt && git add mine.txt && git commit -qm mine)
before="$(git -C "$T/eng" rev-parse HEAD)"
m2 self-update >/dev/null 2>&1; rc=$?
check "diverged engine is refused (exit 2)" '[ "$rc" -eq 2 ] && [ "$(git -C "$T/eng" rev-parse HEAD)" = "$before" ]'

# dirty tree is refused
engine v1.0.0
echo dirty > "$T/eng/v.txt"
m2 self-update >/dev/null 2>&1; rc=$?
check "dirty engine is refused (exit 2)" '[ "$rc" -eq 2 ] && head_is v1.0.0'

# a checkout of main is fast-forwarded to the tag and stays on main; a working branch is never moved
engine v1.0.0
git -C "$T/eng" checkout -q -B main v1.0.0
m2 self-update >/dev/null
check "main checkout: fast-forwarded to the tag" 'head_is v2.0.0-alpha'
check "main checkout: still on branch main" '[ "$(git -C "$T/eng" symbolic-ref --short HEAD)" = main ]'
engine v1.0.0
git -C "$T/eng" checkout -q -b my-feature v1.0.0
M2HERD_UPDATE_INTERVAL_HOURS=0 m2 self-update --auto
check "working branch: auto never moves it" 'head_is v1.0.0 && [ "$(git -C "$T/eng" symbolic-ref --short HEAD)" = my-feature ]'
check "working branch: logged as a branch, not diverged" 'tail -1 "$HOME/.cache/m2herd/update.log" | grep -q "^[0-9T:-]*Z branch"'
check "working branch: --check names the branch" 'm2 self-update --check | grep -q "working branch my-feature"'
rm -f "$HOME/.cache/m2herd/update-auto.stamp"

# main channel keeps the pre-3.0 behaviour: ff-only pull of main
engine v1.0.0
git -C "$T/eng" checkout -q -B main v1.0.0
M2HERD_UPDATE_CHANNEL=main m2 self-update >/dev/null
check "main channel pulls main" 'head_is main'

# --auto: updates, logs, rate-limited, opt-out, never fails, quiet
engine v1.0.0
out="$(m2 self-update --auto 2>&1)"; rc=$?
check "auto exits 0 and prints nothing" '[ "$rc" -eq 0 ] && [ -z "$out" ]'
check "auto updated" 'head_is v2.0.0-alpha'
check "auto logged the move" 'tail -1 "$HOME/.cache/m2herd/update.log" | grep -q "updated .* -> v2.0.0-alpha"'
git -C "$T/eng" checkout -q --detach v1.0.0
m2 self-update --auto
check "auto within the interval does nothing" 'head_is v1.0.0'
M2HERD_UPDATE_INTERVAL_HOURS=0 M2HERD_AUTO_UPDATE=0 m2 self-update --auto
check "M2HERD_AUTO_UPDATE=0 opts out" 'head_is v1.0.0'
echo dirty > "$T/eng/v.txt"
M2HERD_UPDATE_INTERVAL_HOURS=0 m2 self-update --auto; rc=$?
check "auto on a dirty tree: exit 0, skipped, logged" '[ "$rc" -eq 0 ] && head_is v1.0.0 && tail -1 "$HOME/.cache/m2herd/update.log" | grep -q "skipped: uncommitted"'
git -C "$T/eng" checkout -q -- v.txt
git -C "$T/eng" remote set-url origin "$T/nowhere.git"
M2HERD_UPDATE_INTERVAL_HOURS=0 m2 self-update --auto; rc=$?
check "auto offline: exit 0, logged unknown" '[ "$rc" -eq 0 ] && tail -1 "$HOME/.cache/m2herd/update.log" | grep -q "unknown"'

# a release that changes hooks/ or install.sh leaves a visible relink state after --auto
(cd "$T/seed" && mkdir -p hooks && echo x > hooks/new-hook.sh && git add -A && git commit -qm hook && git tag v2.0.0 && git push -q origin main --tags)
engine v2.0.0-alpha
M2HERD_UPDATE_INTERVAL_HOURS=0 m2 self-update --auto
check "auto to a release that changed hooks: relink marker" 'head_is v2.0.0 && grep -q "release v2.0.0 changed install.sh or hooks/" "$HOME/.cache/m2herd/relink-needed"'
m2 self-update --check >/dev/null
check "a later status check keeps the marker" '[ -s "$HOME/.cache/m2herd/relink-needed" ]'
row="$(cd "$T" && rm -rf d0 && git init -q d0 && cd d0 && bash "$REPO/scripts/m2herd.sh" init --goal t >/dev/null && NO_COLOR=1 bash "$REPO/scripts/m2herd.sh" dashboard 2>/dev/null | grep '^update:')"
check "dashboard shows the relink row" 'printf "%s" "$row" | grep -q "install.sh --local"'
ctx="$(echo '{}' | M2HERD_AUTO_UPDATE=0 M2HERD_DIR="$T/d0" bash "$REPO/hooks/m2herd-session.sh" 2>/dev/null | jq -r .hookSpecificOutput.additionalContext)"
check "session digest carries the relink hint" 'printf "%s" "$ctx" | grep -q "m2herd update: release v2.0.0 changed"'
rm -f "$HOME/.cache/m2herd/relink-needed"

# a tag pushed between the fetch and ls-remote is fetched by name, not reported as diverged
engine v2.0.0
mkdir -p "$T/shim"; REALGIT="$(command -v git)"
cat > "$T/shim/git" <<SHIM
#!/bin/sh
case " \$* " in *" ls-remote "*) [ -e "$T/raced" ] || { touch "$T/raced"; (cd "$T/seed" && echo late > v.txt && "$REALGIT" commit -qam late && "$REALGIT" tag v2.1.0 && "$REALGIT" push -q origin main --tags); } ;; esac
exec "$REALGIT" "\$@"
SHIM
chmod +x "$T/shim/git"
out="$(PATH="$T/shim:$PATH" m2 self-update --check)"
check "tag pushed mid-check: behind, not diverged" 'printf "%s" "$out" | grep -q "behind v2.1.0" && git -C "$T/eng" rev-parse -q --verify refs/tags/v2.1.0 >/dev/null'

# the dashboard row reads the four-field cache
printf 'behind 2 %s v9.9.9\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" > "$HOME/.cache/m2herd/update-status"
row="$(cd "$T" && git init -q d && cd d && bash "$REPO/scripts/m2herd.sh" init --goal t >/dev/null && NO_COLOR=1 bash "$REPO/scripts/m2herd.sh" dashboard 2>/dev/null | grep '^update:')"
check "dashboard row names the target tag" 'printf "%s" "$row" | grep -q "2 commit(s) behind v9.9.9"'

# the SessionStart hook starts --auto detached: it returns at once and honours the opt-out
mkdir -p "$T/fakebin"
printf '#!/bin/sh\necho "$@" > "%s/called"; sleep 3\n' "$T" > "$T/fakebin/m2herd"; chmod +x "$T/fakebin/m2herd"
s0=$(date +%s)
echo '{}' | PATH="$T/fakebin:$PATH" bash "$REPO/hooks/m2herd-session.sh" >/dev/null 2>&1
dt=$(( $(date +%s) - s0 )); sleep 1
check "session hook does not wait for the update" '[ "$dt" -lt 2 ]'
check "session hook ran self-update --auto" 'grep -qx "self-update --auto" "$T/called"'
rm -f "$T/called"
echo '{}' | M2HERD_AUTO_UPDATE=0 PATH="$T/fakebin:$PATH" bash "$REPO/hooks/m2herd-session.sh" >/dev/null 2>&1; sleep 1
check "session hook honours M2HERD_AUTO_UPDATE=0" '[ ! -e "$T/called" ]'

echo "test_self_update: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
