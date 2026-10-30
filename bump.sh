#!/usr/bin/env bash
# Usage: bash bump.sh <owner/repo>
# Releases master as the next patch version when the latest tag lags Blizzard's
# live interface numbers; master's unreleased work ships with it.
# Stdout is exactly one result line; logs go to stderr.
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
BASE='' NEXT='' PAIRS='' TAG_URL=''

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
  printf '{"repo":"%s","result":"%s","dry_run":%s,"base":"%s","next":"%s","pairs":"%s","tag_url":"%s","pr_url":""}\n' \
    "$(json_str "$REPO")" "$(json_str "$1")" "$dry" "$(json_str "$BASE")" "$(json_str "$NEXT")" \
    "$(json_str "$PAIRS")" "$(json_str "$TAG_URL")" > "$RESULT_FILE" \
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
if git rev-parse -q --verify "refs/tags/$NEXT" > /dev/null; then
  die "tag $NEXT already exists"
fi
log "base $BASE, next $NEXT"

# Insert $1 as the first bullet under `## [Unreleased]`, after the blank line that
# follows the heading; master's own bullets stay below it.
add_changelog_line() {
  LINE="$1" awk '
    s == 1 { if ($0 ~ /^\r?$/) { print; print ENVIRON["LINE"]; s = 2; next } print ENVIRON["LINE"]; s = 2 }
    s == 2 { if ($0 ~ /^## /) print ""; s = 0 }
    { print }
    /^## \[Unreleased\]/ { s = 1 }
    END { if (s == 1) { print ""; print ENVIRON["LINE"] } }
  ' CHANGELOG.md > CHANGELOG.md.new
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

# 3. Probe on master: run release.sh with a throwaway changelog line to learn the
# changes. BASE is the comparison point, so an interface change already sitting
# unreleased on master still counts.
grep -q '^## \[Unreleased\]' CHANGELOG.md || die "CHANGELOG.md has no ## [Unreleased] heading"
add_changelog_line '- probe'
git add CHANGELOG.md
git commit -q -m 'chore: probe interface bump'
bash scripts/release.sh "${NEXT#v}" || die "release.sh failed"
PAIRS=$(interface_pairs "$BASE" HEAD)
git tag -d "$NEXT" > /dev/null
git reset -q --hard origin/master
git clean -fdq
if [ -z "$PAIRS" ]; then
  log "interface numbers already current"
  result "skipped (up to date)"
  exit 0
fi
log "interface changes: $PAIRS"

# 4. Release: the bump line goes first, master's own bullets follow it.
add_changelog_line "- Updated for the latest World of Warcraft patch (interface $PAIRS)."
git add CHANGELOG.md
git commit -q -m 'chore: note interface bump'
bash scripts/release.sh "${NEXT#v}" || die "release.sh failed"

# 5. Push master and the tag together; the addon's release.yml takes it from there.
if [ -z "$DRY" ]; then
  # git's output stays in the log only: it can hold the token URL.
  if ! PUSH_ERR=$(git push -q --atomic origin master "$NEXT" 2>&1); then
    log "$PUSH_ERR"
    case "$PUSH_ERR" in
      *non-fast-forward* | *'fetch first'*) die "push rejected (master moved); next run retries" ;;
      *) die "push failed (see run log)" ;;
    esac
  fi
  TAG_URL="https://github.com/$REPO/releases/tag/$NEXT"
fi
result "released $NEXT"
