# wow-addon-updater

Weekly bot that keeps my WoW addons on the current game version.

Every Wednesday at 10:00 Copenhagen time it checks each addon below. If Blizzard's live interface numbers have moved past what the addon's latest release tag ships, it releases a patch built from that tag. The patch contains only the TOC interface/version bump and one changelog line. Unreleased work on master is never shipped. Afterwards it merges the release back into master, or opens a PR when the merge conflicts.

The addons it checks are listed in [`addons.json`](addons.json) as `owner/repo` names.

## How it works

`bump.sh <owner/repo>` runs once per entry in `addons.json`, as a matrix job in `.github/workflows/weekly.yml`:

1. Clone the addon, take the highest `vX.Y.Z` tag as the base and the next patch as the new version.
2. Branch from the base tag and copy master's `scripts/` onto it, so release tooling fixes apply. `scripts/` is not packaged.
3. Probe: run the addon's own `scripts/release.sh` and compare the `## Interface` lines. No change means skip.
4. Release: add `- Updated for the latest World of Warcraft patch (interface OLD → NEW).` under `## [Unreleased]`, run `release.sh` again, push the tag only. The addon's own `release.yml` then packages and uploads it.
5. Merge the tag into master. On a conflict, or when the master push is rejected, it opens (or reuses) a PR from `interface-bump/<version>` instead.

## Results

The job summary has one line per addon:

| Result | Meaning |
|---|---|
| `skipped (up to date)` | Nothing to do |
| `released vX.Y.Z, master synced` | Released and merged into master |
| `released vX.Y.Z, master PR #N` | Released; master needs the PR merged |
| `released vX.Y.Z, master sync error: <msg>` | Released; master was not synced. Not retried, so sync it by hand |
| `error: <msg>` | Nothing was pushed |

Dry runs prefix each line with `[dry-run] would have: `.

## Report and notifications

After the matrix finishes, a `report` job collects each addon's result (`bump.sh` writes it as JSON to `RESULT_FILE`) and runs `report.sh addons.json results`. It prints one table, `Addon | Result | Version | Interface | Links`, into the job summary. An addon whose job crashed shows `error: no result (job crashed)`.

If something happened (not a dry run, and any result other than `skipped (up to date)`, errors included), the job also:

1. closes every open issue labelled `weekly-report`,
2. opens `Weekly addon report YYYY-MM-DD` with that label, the table, and an `@` mention of the repo owner, so GitHub notifies you.

A week where every addon is up to date, and every dry run, opens no issue. The job uses the built-in `GITHUB_TOKEN` (`issues: write`), so no extra secret is needed.

## Setup

1. Create a [fine-grained personal access token](https://github.com/settings/personal-access-tokens/new):
   - Resource owner: the account that owns the addons
   - Repository access: only the repos listed in `addons.json`
   - Permissions: Contents read/write, Pull requests read/write (Metadata read is added automatically)
   - Pick an expiry and note it. Once the token expires, every addon shows `error:` in the summary.
2. Save it as the `ADDON_BOT_TOKEN` secret:

   ```bash
   gh secret set ADDON_BOT_TOKEN -R F0rty-Tw0/wow-addon-updater
   ```

## Use it for your own addons

1. Click **Use this template** to get your own copy of this repo.
2. Replace the entries in `addons.json` with your addons (`"you/YourAddon"`).
3. Do the Setup steps above in your copy. Change the `cron`/`timezone` in `.github/workflows/weekly.yml` if you want another time.
4. Run it once with `dry_run` (see Manual run) and check the summary.

Each addon repo must follow this contract, because the bot drives the addon's own tooling and does not know its TOC layout:

- Release tags are `vX.Y.Z`, and there is at least one.
- `CHANGELOG.md` starts its entries with a `## [Unreleased]` heading.
- `scripts/release.sh <x.y.z>`, on a clean tree, will:
  - fetch the live interface numbers (for example from `https://us.version.battle.net/v2/products/<product>/versions`) and write them to the TOC's `## Interface*` lines
  - move the `[Unreleased]` notes into a version section, and refuse when there are none
  - commit, then create the annotated tag `vX.Y.Z`, without pushing
- A workflow on tag push packages and uploads the release (for example with `BigWigsMods/packager`).
- The default branch is `master`.

[F0rty-Tw0/MouseOverTooltip](https://github.com/F0rty-Tw0/MouseOverTooltip) is a working example of `scripts/release.sh`, `scripts/promote_changelog.py` and `.github/workflows/release.yml`.

## Manual run

```bash
gh workflow run weekly.yml -R F0rty-Tw0/wow-addon-updater -f dry_run=true
```

## Tests

```bash
bash bump.test.sh            # all cases
bash bump.test.sh "conflict" # cases whose name contains "conflict"
bash report.test.sh          # report rendering and the notify decision
```

The tests use local bare repos and a stub `gh`, so they never touch GitHub.
