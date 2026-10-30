#!/usr/bin/env bash
# Tests for report.sh: markdown rendering and the notify decision, using result
# fixtures and a stub gh (never touches GitHub).
# Usage: bash report.test.sh [case-name-substring]
set -euo pipefail

HERE=$(cd "$(dirname "$0")" && pwd)
FILTER=${1:-}
T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT
mkdir -p "$T/bin"

unset DRY_RUN GH_STUB_ISSUES GITHUB_REPOSITORY GITHUB_REPOSITORY_OWNER

# Stub gh: logs its args; `issue list` answers GH_STUB_ISSUES; `issue create` saves the body file.
cat > "$T/bin/gh" <<'EOF'
#!/usr/bin/env bash
echo "$*" >> "$GH_LOG"
case "${1:-} ${2:-}" in
  "issue list") printf '%s\n' "${GH_STUB_ISSUES:-}" ;;
  "issue create")
    while [ $# -gt 0 ]; do
      if [ "$1" = "--body-file" ]; then cp "$2" "$GH_BODY"; fi
      shift
    done
    ;;
esac
EOF
chmod +x "$T/bin/gh"

fail() { echo "$*" >&2; exit 1; }
eq() { [ "$1" = "$2" ] || fail "$3: expected [$2] got [$1]"; }
has() { printf '%s\n' "$1" | grep -qxF -- "$2" || fail "$3: missing line [$2] in:
$1"; }
lacks() { if printf '%s' "$1" | grep -qF -- "$2"; then fail "$3: unexpected [$2]"; fi; }

D=""
new_case_dir() { D=$(mktemp -d -p "$T"); mkdir "$D/results"; }

# add_result <file> <repo> <result> <dry:true|false> <base> <next> <pairs> <tag_url> <pr_url>
add_result() {
  printf '{"repo":"%s","result":"%s","dry_run":%s,"base":"%s","next":"%s","pairs":"%s","tag_url":"%s","pr_url":"%s"}\n' \
    "$2" "$3" "$4" "$5" "$6" "$7" "$8" "$9" > "$D/results/$1.json"
}

# run_report [report.sh flags]: sets OUT (stdout), RC; gh log in $D/gh.log, issue body in $D/body.md.
run_report() {
  : > "$D/gh.log"
  set +e
  OUT=$(PATH="$T/bin:$PATH" GH_LOG="$D/gh.log" GH_BODY="$D/body.md" REPORT_DATE=2026-10-30 \
    GH_TOKEN=stub GITHUB_REPOSITORY=me/wow-addon-updater GITHUB_REPOSITORY_OWNER=me \
    bash "$HERE/report.sh" "$@" "$D/addons.json" "$D/results" 2>"$D/err")
  RC=$?
  set -e
  [ "$RC" -eq 0 ] || fail "report.sh exit $RC: $(cat "$D/err")"
}

# Five addons: released twice, skipped, error, and one with no result file.
five_addons() {
  printf '["a/one","a/two","a/three","a/four","a/five"]\n' > "$D/addons.json"
  add_result one a/one "released v1.0.1" false v1.0.0 v1.0.1 "20506 → 20507" \
    https://github.com/a/one/releases/tag/v1.0.1 ""
  add_result two a/two "released v2.3.5" false v2.3.4 v2.3.5 "11509 → 11510, 16001 → 16002" \
    https://github.com/a/two/releases/tag/v2.3.5 https://github.com/a/two/pull/7
  add_result three a/three "skipped (up to date)" false v1.0.0 v1.0.1 "" "" ""
  add_result four a/four "error: clone failed" false "" "" "" "" ""
}

# All addons skipped; $1 = dry flag.
all_skipped() {
  printf '["a/one","a/two"]\n' > "$D/addons.json"
  add_result one a/one "skipped (up to date)" "$1" v1.0.0 v1.0.1 "" "" ""
  add_result two a/two "skipped (up to date)" "$1" v1.0.0 v1.0.1 "" "" ""
}

HEADER='| Addon | Result | Version | Interface | Links |'

case_render() {
  five_addons
  run_report
  has "$OUT" "# Weekly addon report 2026-10-30" "heading"
  has "$OUT" "$HEADER" "table header"
  has "$OUT" "| a/one | released v1.0.1 | v1.0.0 → v1.0.1 | 20506 → 20507 | [Release](https://github.com/a/one/releases/tag/v1.0.1) |" "released row"
  has "$OUT" "| a/two | released v2.3.5 | v2.3.4 → v2.3.5 | 11509 → 11510, 16001 → 16002 | [Release](https://github.com/a/two/releases/tag/v2.3.5) · [PR](https://github.com/a/two/pull/7) |" "pr_url link row"
  has "$OUT" "| a/three | skipped (up to date) | – | – | – |" "skipped row"
  has "$OUT" "| a/four | error: clone failed | – | – | – |" "error row"
  has "$OUT" "| a/five | error: no result (job crashed) | – | – | – |" "missing result row"
  lacks "$OUT" "dry run" "dry marker on a real run"
  eq "$(cat "$D/gh.log")" "" "gh calls without --publish"
}

case_render_order() {
  five_addons
  run_report
  eq "$(printf '%s\n' "$OUT" | grep -o '^| a/[a-z]*' | tr '\n' ' ')" "| a/one | a/two | a/three | a/four | a/five " "row order follows addons.json"
}

case_render_dry() {
  printf '["a/one"]\n' > "$D/addons.json"
  add_result one a/one "released v1.0.1" true v1.0.0 v1.0.1 "20506 → 20507" "" ""
  run_report
  has "$OUT" "# Weekly addon report 2026-10-30 (dry run)" "dry heading"
  has "$OUT" "| a/one | released v1.0.1 | v1.0.0 → v1.0.1 | 20506 → 20507 | – |" "dry row has no links"
}

case_render_pipe_in_cell() {
  printf '["a/one"]\n' > "$D/addons.json"
  add_result one a/one "error: a|b" false "" "" "" "" ""
  run_report
  has "$OUT" '| a/one | error: a\|b | – | – | – |' "pipe escaped"
}

case_render_bad_json() {
  printf '["a/one"]\n' > "$D/addons.json"
  echo '{not json' > "$D/results/result-0.json"
  run_report
  has "$OUT" "| a/one | error: no result (job crashed) | – | – | – |" "unreadable result counts as no result"
}

case_render_no_results_dir() {
  printf '["a/one"]\n' > "$D/addons.json"
  rmdir "$D/results"
  run_report
  has "$OUT" "| a/one | error: no result (job crashed) | – | – | – |" "missing dir"
}

case_notify_all_skipped() {
  all_skipped false
  run_report --publish
  eq "$(cat "$D/gh.log")" "" "gh calls when everything was skipped"
}

case_notify_dry() {
  printf '["a/one"]\n' > "$D/addons.json"
  add_result one a/one "released v1.0.1" true v1.0.0 v1.0.1 "20506 → 20507" "" ""
  run_report --publish
  eq "$(cat "$D/gh.log")" "" "gh calls on a dry run"
}

case_notify_dry_env() {
  # DRY_RUN env also marks the run dry, even when a crashed job left no result file.
  printf '["a/one"]\n' > "$D/addons.json"
  DRY_RUN=1 run_report --publish
  eq "$(cat "$D/gh.log")" "" "gh calls on a dry run with a missing result"
  has "$OUT" "# Weekly addon report 2026-10-30 (dry run)" "dry heading"
}

case_notify_released() {
  five_addons
  GH_STUB_ISSUES=$'3\n4' run_report --publish
  local gh; gh=$(cat "$D/gh.log")
  local lines; lines=$(printf '%s\n' "$gh" | grep -c .)
  eq "$lines" "5" "gh call count: $gh"
  eq "$(printf '%s\n' "$gh" | sed -n 1p)" "label create weekly-report --force -R me/wow-addon-updater" "label create first"
  eq "$(printf '%s\n' "$gh" | sed -n 2p)" "issue list -R me/wow-addon-updater --label weekly-report --state open --json number -q .[].number" "list open"
  eq "$(printf '%s\n' "$gh" | sed -n 3p)" "issue close 3 -R me/wow-addon-updater" "close first old"
  eq "$(printf '%s\n' "$gh" | sed -n 4p)" "issue close 4 -R me/wow-addon-updater" "close second old"
  has "$(printf '%s\n' "$gh" | sed -n 5p | sed 's/ --body-file .*//')" "issue create -R me/wow-addon-updater --title Weekly addon report 2026-10-30 --label weekly-report" "create last"
  local body; body=$(cat "$D/body.md")
  has "$body" "$HEADER" "issue body has the report"
  has "$body" "@me" "issue body mentions the owner"
}

case_notify_error_only() {
  # A crash or error is something that happened: notify.
  printf '["a/one"]\n' > "$D/addons.json"
  run_report --publish
  has "$(sed 's/ --body-file .*//' "$D/gh.log" | tail -1)" "issue create -R me/wow-addon-updater --title Weekly addon report 2026-10-30 --label weekly-report" "issue created"
}

case_notify_one_released_among_skipped() {
  all_skipped false
  add_result two a/two "released v1.0.1" false v1.0.0 v1.0.1 "20506 → 20507" "" ""
  run_report --publish
  has "$(cat "$D/gh.log")" "label create weekly-report --force -R me/wow-addon-updater" "label created"
}

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

run_case "render" case_render
run_case "render order" case_render_order
run_case "render dry" case_render_dry
run_case "render pipe in cell" case_render_pipe_in_cell
run_case "render bad json" case_render_bad_json
run_case "render no results dir" case_render_no_results_dir
run_case "notify all skipped" case_notify_all_skipped
run_case "notify dry" case_notify_dry
run_case "notify dry env" case_notify_dry_env
run_case "notify released" case_notify_released
run_case "notify error only" case_notify_error_only
run_case "notify one released among skipped" case_notify_one_released_among_skipped

[ "$RAN" -gt 0 ] || { echo "FAIL: no case matched '$FILTER'"; exit 1; }
[ "$FAILED" -eq 0 ] || { echo "$FAILED of $RAN FAILED ($PASSED passed)"; exit 1; }
echo "ALL PASS"
