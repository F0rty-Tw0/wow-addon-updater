#!/usr/bin/env bash
# End-to-end tests for bump.sh against local bare remotes and a stub gh.
# Usage: bash bump.test.sh [case-name-substring]
set -euo pipefail

HERE=$(cd "$(dirname "$0")" && pwd)
FILTER=${1:-}
T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT
mkdir -p "$T/bin"

unset DRY_RUN GH_STUB_PR_LIST GH_STUB_CREATE_FAIL FAKE_FAIL FIXTURE_NOTAG FIXTURE_NO_UNRELEASED

# Stub gh: logs its args, answers `pr list` / `pr create` from env.
cat > "$T/bin/gh" <<'EOF'
#!/usr/bin/env bash
echo "$*" >> "$GH_LOG"
case "${1:-} ${2:-}" in
  "pr list") printf '%s\n' "${GH_STUB_PR_LIST:-}" ;;
  "pr create")
    [ -z "${GH_STUB_CREATE_FAIL:-}" ] || exit 1
    echo "https://github.com/F0rty-Tw0/x/pull/7"
    ;;
esac
EOF
chmod +x "$T/bin/gh"

# ---------- helpers ----------

fail() { echo "$*" >&2; exit 1; }
eq() { [ "$1" = "$2" ] || fail "$3: expected [$2] got [$1]"; }
has() { printf '%s' "$1" | grep -qF -- "$2" || fail "$3: missing [$2]"; }
lacks() { if printf '%s' "$1" | grep -qF -- "$2"; then fail "$3: unexpected [$2]"; fi; }

G() { git -c core.autocrlf=false -c user.name=fixture -c user.email=fixture@test "$@"; }

# D = per-case dir, BARE/SEED = current fixture
D="" BARE="" SEED=""
new_case_dir() { D=$(mktemp -d -p "$T"); }

refs() { git --git-dir="$BARE" for-each-ref --format='%(refname) %(objectname)'; }
bare_show() { git --git-dir="$BARE" show "$1"; }
bare_log() { git --git-dir="$BARE" log --format=%s "$1"; }

# Stub release.sh mirroring the real contract; $2 non-empty adds a TOC marker.
write_release_stub() {
  local dest=$1 marker=${2:-}
  mkdir -p "$(dirname "$dest")"
  cat > "$dest" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
ver=${1#v}
[ -z "$(git status --porcelain)" ] || { echo "dirty tree" >&2; exit 1; }
if git show-ref --verify --quiet "refs/tags/v$ver"; then echo "tag exists" >&2; exit 1; fi
[ -z "${FAKE_FAIL:-}" ] || { echo "fetch failed" >&2; exit 1; }
bullets=$(awk '/^## \[Unreleased\]/{f=1;next} /^## \[/{f=0} f && NF' CHANGELOG.md)
[ -n "$bullets" ] || { echo "empty Unreleased" >&2; exit 1; }
sed -i "s/^## Interface: .*/## Interface: $FAKE_INTERFACE/" Addon.toc
sed -i "s/^## Interface-Vanilla: .*/## Interface-Vanilla: $FAKE_VANILLA/" Addon.toc
sed -i "s/^## Interface-Classic: .*/## Interface-Classic: $FAKE_VANILLA/" Addon.toc
sed -i "s/^## Version: .*/## Version: v$ver/" Addon.toc
# EXTRA-HOOK
head=$(awk '/^## \[Unreleased\]/{exit} {print}' CHANGELOG.md)
older=$(awk '/^## \[Unreleased\]/{f=1;next} f&&/^## \[/{g=1} g' CHANGELOG.md)
{
  printf '%s\n\n' "$head"
  printf '## [Unreleased]\n\n## [%s] - %s\n\n%s\n\n%s\n' "$ver" "$(date +%F)" "$bullets" "$older"
} > CHANGELOG.md.new
mv CHANGELOG.md.new CHANGELOG.md
git add -A
git commit -q -m "release: v$ver"
git tag -a "v$ver" -m "Release v$ver"
EOF
  if [ -n "$marker" ]; then
    sed -i 's/^# EXTRA-HOOK$/echo "## X-Tooling: master" >> Addon.toc/' "$dest"
  fi
}

# make_fixture <name> [crlf]: bare remote + seed clone with tag v1.0.0.
# Env knobs: FIXTURE_NOTAG, FIXTURE_NO_UNRELEASED. Sets BARE, SEED; exports FAKE_*.
make_fixture() {
  local name=$1 crlf=${2:-} eol='\n'
  [ -z "$crlf" ] || eol='\r\n'
  BARE="$D/$name.git"
  SEED="$D/$name-seed"
  git init -q --bare -b master "$BARE"
  git init -q -b master "$SEED"
  {
    printf '%s%b' "## Interface: 11509, 16001, 20506" "$eol"
    printf '%s%b' "## Interface-Vanilla: 11509" "$eol"
    printf '%s%b' "## Interface-Classic: 11509" "$eol"
    printf '%s%b' "## Version: v1.0.0" "$eol"
  } > "$SEED/Addon.toc"
  if [ -n "${FIXTURE_NO_UNRELEASED:-}" ]; then
    printf '# Changelog\n\n## [1.0.0] - 2026-01-01\n\n- first\n' > "$SEED/CHANGELOG.md"
  else
    printf '# Changelog\n\n## [Unreleased]\n\n## [1.0.0] - 2026-01-01\n\n- first\n' > "$SEED/CHANGELOG.md"
  fi
  write_release_stub "$SEED/scripts/release.sh"
  G -C "$SEED" add -A
  G -C "$SEED" commit -q -m "init"
  [ -n "${FIXTURE_NOTAG:-}" ] || G -C "$SEED" tag -a v1.0.0 -m "Release v1.0.0"
  G -C "$SEED" remote add origin "$BARE"
  G -C "$SEED" push -q origin master --tags
  export FAKE_INTERFACE="11509, 16001, 20506" FAKE_VANILLA=11509
}

# Commit on top of seed master and push it (after make_fixture).
seed_push() { G -C "$SEED" commit -q -m "$1"; G -C "$SEED" push -q origin master --tags; }

# run_bump <name>: sets OUT (stdout), ERR (stderr), RC.
run_bump() {
  local name=$1
  : > "$D/gh.log"
  set +e
  OUT=$(PATH="$T/bin:$PATH" GH_LOG="$D/gh.log" REPO_URL="$BARE" bash "$HERE/bump.sh" "F0rty-Tw0/$name" 2>"$D/err")
  RC=$?
  set -e
  ERR=$(tail -n 15 "$D/err")
}

assert_out() { # expected-stdout expected-rc
  eq "$OUT" "$1" "stdout (stderr: $ERR)"
  eq "$RC" "$2" "exit code"
}

# CHANGELOG lines under heading `## [x.y.z]` of a tag in the bare repo.
section_of() { # tag version
  bare_show "$1:CHANGELOG.md" | awk -v h="## [$2]" 'index($0,h)==1{f=1;next} /^## \[/{f=0} f'
}

BULLET='- Updated for the latest World of Warcraft patch'

# ---------- cases (expected values come from the plan/spec tables) ----------

case_skip_dry() {
  make_fixture x; export DRY_RUN=1
  local before; before=$(refs)
  run_bump x
  assert_out "[dry-run] would have: skipped (up to date)" 0
  eq "$(refs)" "$before" "bare refs"
}

case_skip_real() {
  make_fixture x
  local before; before=$(refs)
  run_bump x
  assert_out "skipped (up to date)" 0
  eq "$(refs)" "$before" "bare refs"
}

case_release_real() {
  make_fixture x; export FAKE_INTERFACE="11509, 16001, 20507"
  run_bump x
  assert_out "released v1.0.1, master synced" 0
  git --git-dir="$BARE" rev-parse -q --verify refs/tags/v1.0.1 > /dev/null || fail "tag v1.0.1 missing"
  has "$(section_of v1.0.1 1.0.1)" "$BULLET (interface 20506 → 20507)." "changelog line under [1.0.1]"
  lacks "$(git --git-dir="$BARE" log -p v1.0.1)" "- probe" "probe leaked into history"
  has "$(bare_log master)" "chore: merge v1.0.1 interface bump into master" "master merge commit"
}

case_release_dry() {
  make_fixture x; export FAKE_INTERFACE="11509, 16001, 20507" DRY_RUN=1
  local before; before=$(refs)
  run_bump x
  assert_out "[dry-run] would have: released v1.0.1, master synced" 0
  eq "$(refs)" "$before" "bare refs"
}

case_slot_pairing() {
  make_fixture x; export FAKE_INTERFACE="11509, 16002, 20506" FAKE_VANILLA=11510
  run_bump x
  assert_out "released v1.0.1, master synced" 0
  has "$(section_of v1.0.1 1.0.1)" "$BULLET (interface 16001 → 16002, 11509 → 11510)." "slot pairs"
}

case_crlf_toc() {
  make_fixture x crlf; export FAKE_INTERFACE="11509, 16001, 20507"
  run_bump x
  assert_out "released v1.0.1, master synced" 0
  local cl; cl=$(bare_show v1.0.1:CHANGELOG.md)
  has "$cl" "$BULLET (interface 20506 → 20507)." "changelog line"
  if printf '%s' "$cl" | grep -q $'\r'; then fail "CR in changelog"; fi
}

case_semver_sort() {
  make_fixture x; export FAKE_INTERFACE="11509, 16001, 20507"
  echo a > "$SEED/notes.txt"; G -C "$SEED" add notes.txt
  seed_push c9; G -C "$SEED" tag -a v1.0.9 -m v1.0.9
  echo b > "$SEED/notes.txt"; G -C "$SEED" add notes.txt
  seed_push c10; G -C "$SEED" tag -a v1.0.10 -m v1.0.10
  G -C "$SEED" push -q origin --tags
  run_bump x
  assert_out "released v1.0.11, master synced" 0
  git --git-dir="$BARE" rev-parse -q --verify refs/tags/v1.0.11 > /dev/null || fail "tag v1.0.11 missing"
}

case_no_unreleased() {
  FIXTURE_NO_UNRELEASED=1 make_fixture x; export FAKE_INTERFACE="11509, 16001, 20507"
  local before; before=$(refs)
  run_bump x
  assert_out "error: CHANGELOG.md has no ## [Unreleased] heading" 1
  eq "$(refs)" "$before" "bare refs"
}

case_no_tag() {
  FIXTURE_NOTAG=1 make_fixture x; export FAKE_INTERFACE="11509, 16001, 20507"
  local before; before=$(refs)
  run_bump x
  assert_out "error: no release tag" 1
  eq "$(refs)" "$before" "bare refs"
}

case_release_fails() {
  make_fixture x; export FAKE_INTERFACE="11509, 16001, 20507" FAKE_FAIL=1
  local before; before=$(refs)
  run_bump x
  assert_out "error: release.sh failed" 1
  eq "$(refs)" "$before" "bare refs"
}

# --- Task 1.2: master tooling overlay and master sync ---

# Master gets a changelog bullet where the tag side inserts the new section.
master_conflict() {
  printf '# Changelog\n\n## [Unreleased]\n\n- master feature\n\n## [1.0.0] - 2026-01-01\n\n- first\n' > "$SEED/CHANGELOG.md"
  G -C "$SEED" add CHANGELOG.md
  seed_push "master feature"
}

has_ref() { git --git-dir="$BARE" rev-parse -q --verify "$1" > /dev/null || fail "ref $1 missing in bare"; }

case_master_tooling() {
  make_fixture x; export FAKE_INTERFACE="11509, 16001, 20507"
  # tag-only file: present at v1.0.0, deleted on master
  echo x > "$SEED/scripts/old.pyc"
  G -C "$SEED" add -A; G -C "$SEED" commit -q -m "tag-only file"
  G -C "$SEED" tag -f -a v1.0.0 -m "Release v1.0.0"
  G -C "$SEED" push -q -f origin master --tags
  G -C "$SEED" rm -q scripts/old.pyc
  write_release_stub "$SEED/scripts/release.sh" marker
  G -C "$SEED" add scripts/release.sh
  seed_push "new tooling"
  run_bump x
  assert_out "released v1.0.1, master synced" 0
  has "$(bare_show v1.0.1:Addon.toc)" "## X-Tooling: master" "release used master's release.sh"
  lacks "$(git --git-dir="$BARE" ls-tree -r v1.0.1 scripts/)" "old.pyc" "tag-only file removed"
  has "$(bare_log v1.0.1)" "chore: use master release tooling" "overlay commit"
}

case_tooling_noop() {
  make_fixture x; export FAKE_INTERFACE="11509, 16001, 20507"
  run_bump x
  assert_out "released v1.0.1, master synced" 0
  lacks "$(bare_log v1.0.1)" "chore: use master release tooling" "overlay commit"
}

case_conflict_pr() {
  make_fixture x; master_conflict; export FAKE_INTERFACE="11509, 16001, 20507"
  local master_before; master_before=$(git --git-dir="$BARE" rev-parse refs/heads/master)
  run_bump x
  assert_out "released v1.0.1, master PR #7" 0
  has_ref refs/tags/v1.0.1
  has_ref refs/heads/interface-bump/v1.0.1
  eq "$(git --git-dir="$BARE" rev-parse refs/heads/master)" "$master_before" "bare master"
  lacks "$(bare_show v1.0.1:CHANGELOG.md)" "master feature" "tag changelog"
  local gh; gh=$(cat "$D/gh.log")
  has "$gh" "pr create" "gh pr create called"
  has "$gh" "--base master --head interface-bump/v1.0.1" "pr base/head"
  has "$gh" "--title Merge v1.0.1 interface bump into master" "pr title"
  has "$gh" "CHANGELOG.md" "pr body names conflicting file"
}

case_pr_reuse() {
  make_fixture x; master_conflict; export FAKE_INTERFACE="11509, 16001, 20507" GH_STUB_PR_LIST=5
  run_bump x
  assert_out "released v1.0.1, master PR #5" 0
  local gh; gh=$(cat "$D/gh.log")
  has "$gh" "--head interface-bump/v1.0.1 --state open" "pr list query"
  lacks "$gh" "pr create" "second PR"
}

case_push_rejected() {
  make_fixture x; export FAKE_INTERFACE="11509, 16001, 20507"
  cat > "$BARE/hooks/pre-receive" <<'EOF'
#!/bin/sh
while read -r old new ref; do
  if [ "$ref" = refs/heads/master ]; then echo "master is locked" >&2; exit 1; fi
done
exit 0
EOF
  chmod +x "$BARE/hooks/pre-receive"
  run_bump x
  assert_out "released v1.0.1, master PR #7" 0
  has_ref refs/tags/v1.0.1
  has_ref refs/heads/interface-bump/v1.0.1
}

case_sync_error() {
  make_fixture x; master_conflict; export FAKE_INTERFACE="11509, 16001, 20507" GH_STUB_CREATE_FAIL=1
  run_bump x
  assert_out "released v1.0.1, master sync error: gh pr create failed" 1
  has_ref refs/tags/v1.0.1
}

case_conflict_dry() {
  make_fixture x; master_conflict; export FAKE_INTERFACE="11509, 16001, 20507" DRY_RUN=1
  local before; before=$(refs)
  run_bump x
  assert_out "[dry-run] would have: released v1.0.1, master PR" 0
  eq "$(refs)" "$before" "bare refs"
  [ ! -s "$D/gh.log" ] || fail "gh was called: $(cat "$D/gh.log")"
}

# ---------- runner ----------

PASSED=0 FAILED=0 RAN=0
run_case() { # "name" function
  local name=$1 fn=$2 msg rc
  case "$name" in *"$FILTER"*) ;; *) return 0 ;; esac
  RAN=$((RAN + 1))
  new_case_dir
  set +e
  msg=$(set -e; "$fn" 2>&1)
  rc=$?
  set -e
  if [ "$rc" -eq 0 ]; then
    echo "PASS $name"; PASSED=$((PASSED + 1))
  else
    echo "FAIL $name: $(printf '%s' "$msg" | tr '\n' ' ' | cut -c1-600)"; FAILED=$((FAILED + 1))
  fi
}

run_case "skip dry" case_skip_dry
run_case "skip real" case_skip_real
run_case "release real" case_release_real
run_case "release dry" case_release_dry
run_case "slot pairing" case_slot_pairing
run_case "CRLF TOC" case_crlf_toc
run_case "semver sort" case_semver_sort
run_case "no unreleased heading" case_no_unreleased
run_case "no tag" case_no_tag
run_case "release.sh fails" case_release_fails
run_case "master tooling" case_master_tooling
run_case "tooling no-op" case_tooling_noop
run_case "conflict -> PR" case_conflict_pr
run_case "PR reuse" case_pr_reuse
run_case "push rejected" case_push_rejected
run_case "sync error" case_sync_error
run_case "conflict dry" case_conflict_dry

[ "$RAN" -gt 0 ] || { echo "FAIL: no case matched '$FILTER'"; exit 1; }
[ "$FAILED" -eq 0 ] || { echo "$FAILED of $RAN FAILED ($PASSED passed)"; exit 1; }
echo "ALL PASS"
