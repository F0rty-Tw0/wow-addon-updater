#!/usr/bin/env bash
# Usage: bash bump.sh <owner/repo>
# Releases a TOC-only patch when the latest tag lags Blizzard's live interface
# numbers, then syncs master. Stdout is exactly one result line; logs go to stderr.
# Env: GH_TOKEN, DRY_RUN (non-empty = dry run), REPO_URL (clone source override),
# RESULT_FILE (path; also write the outcome there as JSON, for report.sh).
set -euo pipefail

# fd 3 = real stdout (result line only); everything else goes to stderr.
exec 3>&1 1>&2

REPO=${1:?usage: bump.sh <owner/repo>}
DRY=${DRY_RUN:-}

# A relative RESULT_FILE is resolved now, because the script cd's into the clone later.
RESULT_FILE=${RESULT_FILE:-}
case "$RESULT_FILE" in '' | /* | [A-Za-z]:*) ;; *) RESULT_FILE="$PWD/$RESULT_FILE" ;; esac
BASE='' NEXT='' PAIRS='' TAG_URL='' PR_URL=''

log() { echo "bump: $*"; }

# JSON string body: escape backslash and double quote, flatten control whitespace.
json_str() {
  local s=$1
  s=${s//\\/\\\\}
  s=${s//\"/\\\"}
  s=${s//$'\n'/ }
  s=${s//$'\r'/ }
  s=${s//$'\t'/ }
  printf '%s' "$s"
}

write_result_file() { # result text (unprefixed)
  [ -n "$RESULT_FILE" ] || return 0
  local dry=false
  [ -z "$DRY" ] || dry=true
  printf '{"repo":"%s","result":"%s","dry_run":%s,"base":"%s","next":"%s","pairs":"%s","tag_url":"%s","pr_url":"%s"}\n' \
    "$(json_str "$REPO")" "$(json_str "$1")" "$dry" "$(json_str "$BASE")" "$(json_str "$NEXT")" \
    "$(json_str "$PAIRS")" "$(json_str "$TAG_URL")" "$(json_str "$PR_URL")" > "$RESULT_FILE" \
    || log "could not write $RESULT_FILE"
}

result() {
  local prefix=''
  [ -z "$DRY" ] || prefix='[dry-run] would have: '
  write_result_file "$1"
  printf '%s%s\n' "$prefix" "$1" >&3
}
die() { result "error: $1"; exit 1; }

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

URL=${REPO_URL:-}
if [ -z "$URL" ]; then
  : "${GH_TOKEN:?GH_TOKEN is required when REPO_URL is unset}"
  URL="https://x-access-token:$GH_TOKEN@github.com/$REPO"
fi

# 1. Clone with full history and tags; same checkout bytes on Git Bash and ubuntu.
git clone -q -c core.autocrlf=false "$URL" "$WORK/repo" || die "clone failed"
cd "$WORK/repo"
git config user.name 'github-actions[bot]'
git config user.email 'github-actions[bot]@users.noreply.github.com'

# 2. BASE = highest semver tag, NEXT = patch + 1.
BASE=$(git tag -l 'v*' | { grep -E '^v[0-9]+\.[0-9]+\.[0-9]+$' || true; } | sort -V | tail -1)
[ -n "$BASE" ] || die "no release tag"
IFS=. read -r MAJOR MINOR PATCH <<< "${BASE#v}"
NEXT="v$MAJOR.$MINOR.$((PATCH + 1))"
BRANCH="interface-bump/$NEXT"
if git rev-parse -q --verify "refs/tags/$NEXT" > /dev/null; then
  die "tag $NEXT already exists"
fi
log "base $BASE, next $NEXT"

# 3. Release branch at BASE.
git checkout -q -b "$BRANCH" "$BASE"
# Release tooling comes from master: scripts/ becomes an exact copy of master's.
git rm -r -q --ignore-unmatch scripts
git checkout origin/master -- scripts/ || die "master has no scripts/ directory"
git diff --cached --quiet || git commit -q -m 'chore: use master release tooling'
TOOLING=$(git rev-parse HEAD)

# Insert $1 on the line after `## [Unreleased]` (the blank line after it is kept).
add_changelog_line() {
  LINE="$1" awk '{ print } /^## \[Unreleased\]/ { print ENVIRON["LINE"] }' CHANGELOG.md > CHANGELOG.md.new
  mv CHANGELOG.md.new CHANGELOG.md
}

# Print `OLD → NEW` pairs (comma-joined) for ## Interface* lines changed in *.toc
# between $1 and $2. Pairs by file+key and by slot index; drops equal, dedupes.
interface_pairs() {
  git diff "$1" "$2" -- '*.toc' | tr -d '\r' | awk '
    function parse(l,   k, v) {
      k = l; sub(/:.*/, "", k)
      v = l; sub(/^[^:]*:[ ]*/, "", v); sub(/[ ]+$/, "", v)
      KEY = file SUBSEP k; VAL = v
    }
    /^\+\+\+ /   { file = $0; next }
    /^--- /      { next }
    /^-## Interface/ { parse(substr($0, 2)); if (!(KEY in old)) order[++n] = KEY; old[KEY] = VAL; next }
    /^\+## Interface/ { parse(substr($0, 2)); nw[KEY] = VAL; next }
    END {
      for (i = 1; i <= n; i++) {
        k = order[i]
        if (!(k in nw)) continue
        a = split(old[k], o, /[ ]*,[ ]*/); b = split(nw[k], w, /[ ]*,[ ]*/)
        for (s = 1; s <= a && s <= b; s++) {
          if (o[s] == w[s]) continue
          p = o[s] " → " w[s]
          if (p in seen) continue
          seen[p] = 1
          out = out (out == "" ? "" : ", ") p
        }
      }
      print out
    }'
}

# 4. Probe: run release.sh with a throwaway changelog line to learn the changes.
grep -q '^## \[Unreleased\]' CHANGELOG.md || die "CHANGELOG.md has no ## [Unreleased] heading"
add_changelog_line '- probe'
git add CHANGELOG.md
git commit -q -m 'chore: probe interface bump'
bash scripts/release.sh "${NEXT#v}" || die "release.sh failed"
PAIRS=$(interface_pairs "$TOOLING" HEAD)
git tag -d "$NEXT" > /dev/null
git reset -q --hard "$TOOLING"
git clean -fdq
if [ -z "$PAIRS" ]; then
  log "interface numbers already current"
  result "skipped (up to date)"
  exit 0
fi
log "interface changes: $PAIRS"

# 5. Release.
add_changelog_line "- Updated for the latest World of Warcraft patch (interface $PAIRS)."
git add CHANGELOG.md
git commit -q -m 'chore: note interface bump'
bash scripts/release.sh "${NEXT#v}" || die "release.sh failed"

# 6. Push the tag only; the addon's release.yml takes it from there.
if [ -z "$DRY" ]; then
  git push -q origin "$NEXT" || die "push of $NEXT failed"
  TAG_URL="https://github.com/$REPO/releases/tag/$NEXT"
fi

# 7. Sync master.
sync_fail() { result "released $NEXT, master sync error: $1"; exit 1; }

# Open (or reuse) the PR that merges $BRANCH into master; $1 = why, for the body.
master_pr() {
  if [ -n "$DRY" ]; then
    result "released $NEXT, master PR"
    exit 0
  fi
  git push -q origin "$BRANCH" || sync_fail "push of $BRANCH failed"
  local n url
  n=$(gh pr list -R "$REPO" --head "$BRANCH" --state open --json number -q '.[0].number // empty') \
    || sync_fail "gh pr list failed"
  [[ $n =~ ^[0-9]+$ ]] || n=''
  if [ -z "$n" ]; then
    url=$(gh pr create -R "$REPO" --base master --head "$BRANCH" \
      --title "Merge $NEXT interface bump into master" --body "$1") \
      || sync_fail "gh pr create failed"
    n=${url##*/}
    [[ $n =~ ^[0-9]+$ ]] || sync_fail "gh pr create failed"
  fi
  PR_URL="https://github.com/$REPO/pull/$n"
  result "released $NEXT, master PR #$n"
  exit 0
}

git checkout -q -B master origin/master
if git merge -q --no-ff -m "chore: merge $NEXT interface bump into master" "$BRANCH"; then
  if [ -z "$DRY" ] && ! git push -q origin master; then
    log "push of master rejected; falling back to a PR"
    master_pr "master moved during the release, so $BRANCH could not be pushed to it."
  fi
  result "released $NEXT, master synced"
  exit 0
fi
CONFLICTS=$(git diff --name-only --diff-filter=U | awk 'NR > 1 { printf ", " } { printf "%s", $0 }')
git merge --abort || sync_fail "git merge --abort failed"
[ -n "$CONFLICTS" ] || sync_fail "merge into master failed"
master_pr "Conflicting files: $CONFLICTS"
