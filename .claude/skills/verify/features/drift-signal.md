# Update drift signal

When a newer claudefuel release is published, line 1 gains a yellow `↗ /claudefuel.update`, so the user knows to upgrade. It stays silent when the installed version is equal or newer, and when offline.

## Sub-features

- `drift-newer` shows `↗ /claudefuel.update` when the cached upstream is strictly newer than the installed version (`sort -V`).
- `drift-equal` shows no segment when the versions are equal.
- `drift-installed-ahead` shows no segment when the installed version is newer than the cache (a fresh update outrunning the 6h TTL).
- `drift-first-run-offline` renders without a segment or a crash when there is no cache and `CLAUDEFUEL_OFFLINE=1`.
- `drift-live-fetch` fetches `main`'s header from GitHub when the cache is missing or older than 6h, and writes `claudefuel-version.json`.

## How to get to it (user POV)

- Any session. The segment appears on line 1 after the next refresh following a release.

## Driving it with cf-render

Preconditions:

- `cf-doctor` exits 0. Note the installed version it reports.

- **Newer upstream.** Run `R --label drift-newer --stdin @.claude/skills/verify/fixtures/stdin-minimal.json --upstream 9.9.9`. Line 1 ends `| ↗ /claudefuel.update`, and `run-1.colors.txt` shows `{yellow}↗ /claudefuel.update{/}`. Line count is unchanged.
- **Equal.** Run `R --label drift-equal` (the default seed equals the installed version). There is no `↗`.
- **Installed ahead.** Run `R --label drift-installed-ahead --upstream 0.0.1`. There is no `↗`.
- **Offline first run.** Run `R --label drift-first-run-offline --no-upstream`. Exit 0, line 1 present, no `↗`. `net.log` has no `raw.githubusercontent.com` line. `state-after/` has no `claudefuel-version.json`.
- **Live fetch.** Real public read of GitHub. Run `R --label drift-live-fetch --no-upstream --allow-github --stdin @.claude/skills/verify/fixtures/stdin-minimal.json`. `net.log` has `curl https://raw.githubusercontent.com/FlorianRiquelme/claudefuel/main/statusline.sh`. `state-after/claudefuel-version.json` holds `main`'s version. `↗` appears iff that version is newer than this checkout's.
- **Proof.** Cite `manifest.txt` `script_version`, the seeded or fetched `claudefuel-version.json`, and line 1.

## Gotchas

- The installed version is read from the header of the script being run (`--script`), not from `~/.claude`. Bumping the header in the checkout changes every drift result.
- The live fetch reads `main`, not the latest tag. Right after a version-bump merge, `main` is ahead of the release that `/claudefuel.update` would install.
- `--allow-github` also unsets `CLAUDEFUEL_OFFLINE`, so `net.log` gains a second set of `security` lookups from the prepaid path. Expected.
