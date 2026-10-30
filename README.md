# wow-addon-updater

Weekly bot that keeps my WoW addons on the current game version.

Every Wednesday at 10:00 Copenhagen time it checks each addon below. If Blizzard's live interface numbers have moved past what the addon's latest release tag ships, it releases a patch from master. Whatever is unreleased on master ships with it: the interface/version bump, an `Updated for the latest World of Warcraft patch` line at the top of `[Unreleased]`, and the rest of that list. The release commit and tag are pushed to master together.

The addons it checks are listed in [`addons.json`](addons.json) as `owner/repo` names.

## How it works

`bump.sh <owner/repo>` runs once per entry in `addons.json`, as a matrix job in `.github/workflows/weekly.yml`:

1. Clone the addon, take the highest `vX.Y.Z` tag as the base and the next patch as the new version.
2. Probe on master: add a throwaway `- probe` bullet, run the addon's own `scripts/release.sh`, and compare the `## Interface` lines against the base tag (so a bump already sitting unreleased on master still counts, including a hand edit of an interface number). No change means skip. Then reset to `origin/master`.
3. Release: add `- Updated for the latest World of Warcraft patch (interface OLD → NEW).` as the first bullet under `## [Unreleased]`, master's own bullets after it, and run `release.sh` again.
4. Push `master` and the tag in one atomic push. The addon's own `release.yml` then packages and uploads it. If the push fails, nothing is pushed: `push rejected (master moved)` retries next run, `push failed (see run log)` (auth, network) needs a look at the job log.

## Results

The job summary has one line per addon:

| Result | Meaning |
|---|---|
| `skipped (up to date)` | Nothing to do |
| `released vX.Y.Z` | Released from master; master and the tag are pushed |
| `error: <msg>` | Nothing was pushed (`push rejected (master moved)` retries next run) |

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
   - Permissions: Contents read/write (Metadata read is added automatically)
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
bash bump.test.sh "push"     # cases whose name contains "push"
bash report.test.sh          # report rendering and the notify decision
```

The tests use local bare repos, so they never touch GitHub.
