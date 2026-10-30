#!/usr/bin/env bash
# End-to-end tests for bump.sh against local bare remotes (no gh, no network).
# Usage: bash bump.test.sh [case-name-substring]
set -euo pipefail

HERE=$(cd "$(dirname "$0")" && pwd)
FILTER=${1:-}
T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT

unset DRY_RUN RESULT_FILE FAKE_FAIL FIXTURE_NOTAG FIXTURE_NO_UNRELEASED

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

# Stub release.sh mirroring the real contract.
write_release_stub() {
  local dest=$1
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
  set +e
  rm -f "$D/result.json"
  OUT=$(REPO_URL="$BARE" RESULT_FILE="$D/result.json" bash "$HERE/bump.sh" "F0rty-Tw0/$name" 2>"$D/err")
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

# Python is "python3" on ubuntu, "python" on Git Bash (python3 there can be a Store stub).
PY=""
for c in python3 python; do
  if "$c" -c 'import sys' > /dev/null 2>&1; then PY=$c; break; fi
done
[ -n "$PY" ] || fail "python not found"

# result_json: the RESULT_FILE of the last run as canonical JSON (sorted keys, ASCII-escaped);
# fails when the file is missing or not valid JSON.
result_json() {
  [ -f "$D/result.json" ] || fail "RESULT_FILE not written (stderr: $ERR)"
  PYTHONIOENCODING=utf-8 "$PY" -c 'import json,sys; print(json.dumps(json.load(open(sys.argv[1], encoding="utf-8")), sort_keys=True, separators=(",", ":"), ensure_ascii=False))' "$D/result.json"     || fail "RESULT_FILE is not valid JSON: $(cat "$D/result.json")"
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
  assert_out "released v1.0.1" 0
  git --git-dir="$BARE" rev-parse -q --verify refs/tags/v1.0.1 > /dev/null || fail "tag v1.0.1 missing"
  has "$(section_of v1.0.1 1.0.1)" "$BULLET (interface 20506 → 20507)." "changelog line under [1.0.1]"
  lacks "$(git --git-dir="$BARE" log -p v1.0.1)" "- probe" "probe leaked into history"
  eq "$(git --git-dir="$BARE" rev-parse refs/heads/master)" "$(git --git-dir="$BARE" rev-parse 'v1.0.1^{commit}')" "master is the tag commit"
  # Empty [Unreleased]: blank lines stay on both sides of the new bullet.
  eq "$(bare_show master~1:CHANGELOG.md)" "$(printf '# Changelog\n\n## [Unreleased]\n\n%s (interface 20506 → 20507).\n\n## [1.0.0] - 2026-01-01\n\n- first' "$BULLET")" "changelog layout before release.sh"
}

case_release_dry() {
  make_fixture x; export FAKE_INTERFACE="11509, 16001, 20507" DRY_RUN=1
  local before; before=$(refs)
  run_bump x
  assert_out "[dry-run] would have: released v1.0.1" 0
  eq "$(refs)" "$before" "bare refs"
}

case_slot_pairing() {
  make_fixture x; export FAKE_INTERFACE="11509, 16002, 20506" FAKE_VANILLA=11510
  run_bump x
  assert_out "released v1.0.1" 0
  has "$(section_of v1.0.1 1.0.1)" "$BULLET (interface 16001 → 16002, 11509 → 11510)." "slot pairs"
}

case_crlf_toc() {
  make_fixture x crlf; export FAKE_INTERFACE="11509, 16001, 20507"
  run_bump x
  assert_out "released v1.0.1" 0
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
  assert_out "released v1.0.11" 0
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

# --- Addendum 2026-10-30c: release from master ---

has_ref() { git --git-dir="$BARE" rev-parse -q --verify "$1" > /dev/null || fail "ref $1 missing in bare"; }

case_unreleased_shipped() {
  make_fixture x; export FAKE_INTERFACE="11509, 16001, 20507"
  printf '# Changelog\n\n## [Unreleased]\n\n- master feature\n\n## [1.0.0] - 2026-01-01\n\n- first\n' > "$SEED/CHANGELOG.md"
  G -C "$SEED" add CHANGELOG.md
  seed_push "master feature"
  run_bump x
  assert_out "released v1.0.1" 0
  has_ref refs/tags/v1.0.1
  local want; want=$(printf '%s (interface 20506 → 20507).\n- master feature' "$BULLET")
  eq "$(section_of v1.0.1 1.0.1 | sed '/^$/d')" "$want" "tag section: bump line first, then master's bullet"
  eq "$(section_of master 1.0.1 | sed '/^$/d')" "$want" "master section"
  eq "$(section_of master Unreleased | sed '/^$/d')" "" "[Unreleased] empty on master"
  # Exact layout handed to release.sh (the commit before the release commit).
  eq "$(bare_show master~1:CHANGELOG.md)" "$(printf '# Changelog\n\n## [Unreleased]\n\n%s (interface 20506 → 20507).\n- master feature\n\n## [1.0.0] - 2026-01-01\n\n- first' "$BULLET")" "changelog layout before release.sh"
  eq "$(git --git-dir="$BARE" rev-parse refs/heads/master)" "$(git --git-dir="$BARE" rev-parse 'v1.0.1^{commit}')" "master is the tag commit"
  lacks "$(git --git-dir="$BARE" log -p master)" "- probe" "probe leaked into history"
}

case_already_bumped_on_master() {
  make_fixture x; export FAKE_INTERFACE="11509, 16001, 20507"
  sed -i 's/20506/20507/' "$SEED/Addon.toc"
  G -C "$SEED" add Addon.toc
  seed_push "toc already bumped"
  run_bump x
  assert_out "released v1.0.1" 0
  has_ref refs/tags/v1.0.1
  has "$(section_of v1.0.1 1.0.1)" "$BULLET (interface 20506 → 20507)." "changelog line"
}

case_push_rejected() {
  make_fixture x; export FAKE_INTERFACE="11509, 16001, 20507"
  printf '#!/bin/sh\necho "master is locked" >&2\nexit 1\n' > "$BARE/hooks/pre-receive"
  chmod +x "$BARE/hooks/pre-receive"
  local before; before=$(refs)
  run_bump x
  assert_out "error: push failed (see run log)" 1
  eq "$(refs)" "$before" "bare refs"
  if git --git-dir="$BARE" rev-parse -q --verify refs/tags/v1.0.1 > /dev/null; then fail "tag v1.0.1 pushed"; fi
}

# Only master is refused: the atomic push must not land the tag alone.
case_master_only_rejected() {
  make_fixture x; export FAKE_INTERFACE="11509, 16001, 20507"
  printf '#!/bin/sh\n[ "$1" = refs/heads/master ] && { echo "no master" >&2; exit 1; }\nexit 0\n' > "$BARE/hooks/update"
  chmod +x "$BARE/hooks/update"
  local before; before=$(refs)
  run_bump x
  assert_out "error: push failed (see run log)" 1
  eq "$(refs)" "$before" "bare refs"
}

# Someone pushes to master while release.sh runs: nothing is pushed, and the
# next run releases on top of their commit.
case_master_moved() {
  make_fixture x; export FAKE_INTERFACE="11509, 16001, 20507"
  local other="$D/other"; G clone -q "$BARE" "$other"
  # release.sh runs twice per bump (probe, release); push from $other on the 2nd call.
  cat > "$SEED/scripts/race.sh" <<EOR
#!/usr/bin/env bash
c=\$(cat "$D/count" 2>/dev/null || echo 0); echo \$((c+1)) > "$D/count"
if [ "\$c" = 1 ]; then
  git -C "$other" pull -q
  echo z >> "$other/z.txt"
  git -C "$other" -c user.name=o -c user.email=o@o add z.txt
  git -C "$other" -c user.name=o -c user.email=o@o commit -qm race
  git -C "$other" push -q origin master
fi
EOR
  sed -i '2a bash "$(dirname "$0")/race.sh"' "$SEED/scripts/release.sh"
  G -C "$SEED" add -A; seed_push "race hook"
  run_bump x
  assert_out "error: push rejected (master moved); next run retries" 1
  if git --git-dir="$BARE" rev-parse -q --verify refs/tags/v1.0.1 > /dev/null; then fail "tag v1.0.1 pushed"; fi
  echo 5 > "$D/count"
  run_bump x
  assert_out "released v1.0.1" 0
  has "$(bare_log master)" "race" "release built on the racing commit"
}

# --- Addendum 2026-10-30: RESULT_FILE json ---

case_json_release_real() {
  make_fixture x; export FAKE_INTERFACE="11509, 16001, 20507"
  run_bump x
  assert_out "released v1.0.1" 0
  eq "$(result_json)" '{"base":"v1.0.0","dry_run":false,"next":"v1.0.1","pairs":"20506 → 20507","pr_url":"","repo":"F0rty-Tw0/x","result":"released v1.0.1","tag_url":"https://github.com/F0rty-Tw0/x/releases/tag/v1.0.1"}' "result json"
}

case_json_skip_dry() {
  make_fixture x; export DRY_RUN=1
  run_bump x
  assert_out "[dry-run] would have: skipped (up to date)" 0
  eq "$(result_json)" '{"base":"v1.0.0","dry_run":true,"next":"v1.0.1","pairs":"","pr_url":"","repo":"F0rty-Tw0/x","result":"skipped (up to date)","tag_url":""}' "result json"
}

case_json_release_dry() {
  make_fixture x; export FAKE_INTERFACE="11509, 16001, 20507" DRY_RUN=1
  run_bump x
  assert_out "[dry-run] would have: released v1.0.1" 0
  eq "$(result_json)" '{"base":"v1.0.0","dry_run":true,"next":"v1.0.1","pairs":"20506 → 20507","pr_url":"","repo":"F0rty-Tw0/x","result":"released v1.0.1","tag_url":""}' "result json"
}

case_json_error() {
  FIXTURE_NOTAG=1 make_fixture x
  run_bump x
  assert_out "error: no release tag" 1
  eq "$(result_json)" '{"base":"","dry_run":false,"next":"","pairs":"","pr_url":"","repo":"F0rty-Tw0/x","result":"error: no release tag","tag_url":""}' "result json"
}

case_json_escaping() {
  make_fixture x
  run_bump 'we"ird\name'
  assert_out "skipped (up to date)" 0
  has "$(result_json)" '"repo":"F0rty-Tw0/we\"ird\\name"' "repo escaped"
}

case_json_relative_path() {
  make_fixture x
  ( cd "$D" && REPO_URL="$BARE" RESULT_FILE="rel.json" bash "$HERE/bump.sh" F0rty-Tw0/x > /dev/null 2>&1 )
  [ -f "$D/rel.json" ] || fail "relative RESULT_FILE not written relative to the caller's cwd"
}

case_no_result_file_by_default() {
  make_fixture x
  ( cd "$D" && REPO_URL="$BARE" bash "$HERE/bump.sh" F0rty-Tw0/x > /dev/null 2>&1 )
  eq "$(find "$D" -name '*.json' | wc -l | tr -d ' ')" "0" "json files written without RESULT_FILE"
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
run_case "unreleased shipped" case_unreleased_shipped
run_case "already bumped on master" case_already_bumped_on_master
run_case "push rejected" case_push_rejected
run_case "master only rejected" case_master_only_rejected
run_case "master moved" case_master_moved
run_case "json release real" case_json_release_real
run_case "json skip dry" case_json_skip_dry
run_case "json release dry" case_json_release_dry
run_case "json error" case_json_error
run_case "json escaping" case_json_escaping
run_case "json relative path" case_json_relative_path
run_case "no result file by default" case_no_result_file_by_default

[ "$RAN" -gt 0 ] || { echo "FAIL: no case matched '$FILTER'"; exit 1; }
[ "$FAILED" -eq 0 ] || { echo "$FAILED of $RAN FAILED ($PASSED passed)"; exit 1; }
echo "ALL PASS"
