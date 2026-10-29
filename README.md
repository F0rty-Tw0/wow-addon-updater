# wow-addon-updater

Weekly bot that keeps my WoW addons on the current game version.

Every Wednesday at 10:00 Copenhagen time it checks each addon below. If Blizzard's live interface numbers have moved past what the addon's latest release tag ships, it releases a patch built from that tag. The patch contains only the TOC interface/version bump and one changelog line. Unreleased work on master is never shipped. Afterwards it merges the release back into master, or opens a PR when the merge conflicts.

Addons:

- [WhisperMessenger](https://github.com/F0rty-Tw0/WhisperMessenger)
- [LevelUpInfo](https://github.com/F0rty-Tw0/LevelUpInfo)
- [MouseOverTooltip](https://github.com/F0rty-Tw0/MouseOverTooltip)
- [RaidGroupWrap](https://github.com/F0rty-Tw0/RaidGroupWrap)
- [ShoulderCam](https://github.com/F0rty-Tw0/ShoulderCam)

## How it works

`bump.sh <owner/repo>` runs once per addon, as a matrix job in `.github/workflows/weekly.yml`:

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

## Setup

1. Create a [fine-grained personal access token](https://github.com/settings/personal-access-tokens/new):
   - Resource owner: `F0rty-Tw0`
   - Repository access: only the five addon repos above
   - Permissions: Contents read/write, Pull requests read/write (Metadata read is added automatically)
   - Pick an expiry and note it. Once the token expires, every addon shows `error:` in the summary.
2. Save it as the `ADDON_BOT_TOKEN` secret:

   ```bash
   gh secret set ADDON_BOT_TOKEN -R F0rty-Tw0/wow-addon-updater
   ```

## Manual run

```bash
gh workflow run weekly.yml -R F0rty-Tw0/wow-addon-updater -f dry_run=true
```

## Tests

```bash
bash bump.test.sh            # all cases
bash bump.test.sh "conflict" # cases whose name contains "conflict"
```

The tests use local bare repos and a stub `gh`, so they never touch GitHub.
