#!/usr/bin/env bash
# Usage: bash report.sh [--publish] <addons.json> <results-dir>
# Prints a markdown report of the weekly run: one row per addon in addons.json,
# read from the JSON files bump.sh wrote (RESULT_FILE) into <results-dir>.
# With --publish, and when something happened (not a dry run, and any result other
# than "skipped (up to date)"), also closes the open `weekly-report` issues and opens
# a new one with the report and an @mention of the repo owner.
# Env: DRY_RUN (non-empty = dry run), REPORT_DATE (default: today, UTC),
#      with --publish: GH_TOKEN, GITHUB_REPOSITORY, GITHUB_REPOSITORY_OWNER.
set -euo pipefail

PUBLISH=''
if [ "${1:-}" = "--publish" ]; then PUBLISH=1; shift; fi
ADDONS=${1:?usage: report.sh [--publish] <addons.json> <results-dir>}
DIR=${2:?usage: report.sh [--publish] <addons.json> <results-dir>}

# "python3" on ubuntu; "python" on Git Bash (where python3 can be a Store stub).
PY=''
for c in python3 python; do
  if "$c" -c 'import sys' > /dev/null 2>&1; then PY=$c; break; fi
done
[ -n "$PY" ] || { echo "report.sh: python not found" >&2; exit 1; }

NOTIFY_FILE=$(mktemp)
BODY_FILE=$(mktemp)
trap 'rm -f "$NOTIFY_FILE" "$BODY_FILE"' EXIT

read -r -d '' RENDER <<'PY' || true
import glob, json, os, sys, datetime

addons_path, results_dir, notify_file = sys.argv[1:4]
sys.stdout.reconfigure(encoding="utf-8", newline="\n")

with open(addons_path, encoding="utf-8") as f:
    addons = json.load(f)

results = {}
for path in sorted(glob.glob(os.path.join(results_dir, "**", "*.json"), recursive=True)):
    try:
        with open(path, encoding="utf-8") as f:
            r = json.load(f)
        results[r["repo"]] = r
    except (OSError, ValueError, KeyError, TypeError):
        pass  # unreadable file: its addon shows as "no result"

NONE = "–"
MISSING = "error: no result (job crashed)"
SKIPPED = "skipped (up to date)"

def cell(text):
    return str(text).replace("|", "\\|").replace("\n", " ")

dry = bool(os.environ.get("DRY_RUN")) or any(r.get("dry_run") is True for r in results.values())
notify = False
rows = []
for repo in addons:
    r = results.get(repo)
    if r is None:
        result, version, interface, links = MISSING, NONE, NONE, NONE
    else:
        result = r.get("result") or MISSING
        released = result.startswith("released")
        version = f'{r.get("base")} → {r.get("next")}' if released and r.get("base") and r.get("next") else NONE
        interface = r.get("pairs") or NONE
        links = " · ".join(
            f"[{label}]({r[key]})" for label, key in (("Release", "tag_url"), ("PR", "pr_url")) if r.get(key)
        ) or NONE
    if result != SKIPPED:
        notify = True
    rows.append(f"| {cell(repo)} | {cell(result)} | {cell(version)} | {cell(interface)} | {links} |")

date = os.environ.get("REPORT_DATE") or datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%d")
print(f'# Weekly addon report {date}{" (dry run)" if dry else ""}')
print()
print("| Addon | Result | Version | Interface | Links |")
print("|---|---|---|---|---|")
print("\n".join(rows))

with open(notify_file, "w", encoding="utf-8") as f:
    f.write("yes" if notify and not dry else "no")
PY

REPORT=$("$PY" -I -c "$RENDER" "$ADDONS" "$DIR" "$NOTIFY_FILE")
printf '%s\n' "$REPORT"

[ -n "$PUBLISH" ] || exit 0
[ "$(cat "$NOTIFY_FILE")" = yes ] || { echo "report.sh: nothing happened or dry run; no issue" >&2; exit 0; }

: "${GITHUB_REPOSITORY:?GITHUB_REPOSITORY is required with --publish}"
: "${GITHUB_REPOSITORY_OWNER:?GITHUB_REPOSITORY_OWNER is required with --publish}"
TITLE=$(printf '%s\n' "$REPORT" | head -1 | sed 's/^# //')

printf '%s\n\n@%s\n' "$REPORT" "$GITHUB_REPOSITORY_OWNER" > "$BODY_FILE"
gh label create weekly-report --force -R "$GITHUB_REPOSITORY" >&2
OLD=$(gh issue list -R "$GITHUB_REPOSITORY" --label weekly-report --state open --json number -q '.[].number')
for n in $OLD; do
  gh issue close "$n" -R "$GITHUB_REPOSITORY" >&2
done
gh issue create -R "$GITHUB_REPOSITORY" --title "$TITLE" --label weekly-report --body-file "$BODY_FILE" >&2
