---
name: release
description: Determine the next version and run the GitHub Actions Mac release pipeline.
---

Cut a new Mac release of Clearly. See `AGENTS.md` "Versioning" and "Commit message rule". This skill derives the version from the Mac tag history and runs the release pipeline.

## Instructions

### Step 1: Verify prerequisites

1. GitHub CLI authentication works (`gh auth status`).
2. The repository has all secrets required by `.github/workflows/release.yml`. Check names with `gh secret list`; never print secret values:
   - `APPLE_TEAM_ID`
   - `ASC_ISSUER_ID`
   - `ASC_KEY_ID`
   - `ASC_PRIVATE_KEY`
   - `MACOS_CERTIFICATE_P12_BASE64`
   - `SIGNING_IDENTITY_NAME`
   - `SPARKLE_ED_PRIVATE_KEY`
   - `MACOS_CERTIFICATE_PASSWORD` is optional when the exported P12 has no password.
3. Working tree clean (`git status --porcelain`). If dirty, stop and ask the user to commit or stash.
4. On the `main` branch. If not, stop.
5. Pull the latest `origin/main` with `git pull --ff-only` before preparing the release.

### Step 2: Determine the next version

Steps:
1. Get the latest tag:
   ```bash
   git tag -l 'v*' | sort -V | tail -1
   ```
2. Get commits since that tag:
   ```bash
   git log <latest_tag>..HEAD --oneline --format='%s'
   ```
3. **Un-scoped commit guard.** If ANY commit in that range does NOT start with `[mac]` or `[chore]`, stop and list those commits to the user:
   > "Found commits without a scope prefix. Fix with `git commit --amend` or `git rebase -i` before releasing, or tell me to proceed anyway (commits will fall through the filter and may land in the wrong changelog)."
   Use `mcp__conductor__AskUserQuestion` to ask whether to halt or proceed anyway.
4. Filter commits with `^\[mac\]`. If zero commits match after filtering, stop: "No Mac product commits since <tag>. Nothing to release."
5. Apply semver logic to the scoped commit list:
   - Any commit containing `feat:` or `feat(` after the scope → **minor** bump
   - All commits are `fix:` / `chore:` / `docs:` style → **patch** bump
   - Any commit contains `BREAKING CHANGE` or `!:` → ask the user
   - Ambiguous / no conventional-commit markers → ask via `mcp__conductor__AskUserQuestion`:
     - question: "Commits since the last release don't clearly indicate the version bump. What version should this release be?"
     - header: "Release version"
     - multiSelect: false
     - options: "Patch (X.Y.Z+1)", "Minor (X.Y+1.0)", "Major (X+1.0.0)", "Custom"

### Step 3: Confirm the version

Confirm before proceeding. Show the tag (`v<VERSION>`) and the scoped commit list. Use `mcp__conductor__AskUserQuestion`:
- question: "Release as <TAG>? Commits included:\n<scoped commit list>"
- header: "Confirm release"
- multiSelect: false
- options:
  - "Yes, release <TAG>"
  - "Use a different version"
  - "Cancel"

If "Use a different version", ask for the version. If "Cancel", stop.

### Step 3.5: Update the changelog

1. Check if the changelog has an `## [Unreleased]` section with content.
2. If `## [Unreleased]` is empty or missing, draft entries from the **scoped** commit list (same regex used above):
   - **Rewrite each entry user-facing.** Don't echo commit messages. Describe what changed from the user's perspective.
   - Bad: "feat: synchronized scroll and fix editor font size"
   - Good: "Editor and preview scroll together so you always see what you're editing"
   - Strip the `[scope]` prefix and any `feat:`/`fix:` markers.
   - Drop entries with no user-visible impact (internal refactors, test harness updates).
   - Keep entries succinct — one line each, no technical jargon.
   - Confirm the drafted entries with `mcp__conductor__AskUserQuestion`.
3. Rename `## [Unreleased]` to `## [VERSION] - YYYY-MM-DD` (today's date).
4. Add a new empty `## [Unreleased]` above it.

### Step 4: Update version strings

1. Edit `project.yml`. Update `MARKETING_VERSION` in both targets: `Clearly` and `ClearlyQuickLook`.
2. Commit and push the changelog and version update:
   ```bash
   git add project.yml CHANGELOG.md
   git commit -m "[mac] Prepare v<VERSION> release"
   git push origin main
   ```

### Step 5: Trigger and monitor the GitHub release

```bash
git tag "v<VERSION>"
git push origin "v<VERSION>"
```

The tag triggers `.github/workflows/release.yml`, which runs `scripts/release-ci.sh` and handles: xcodegen → archive → export → DMG → notarize → staple → latest-only Sparkle appcast → GitHub Release.

Find the run whose `headSha` matches the tag and watch it to completion:

```bash
gh run list --workflow release.yml --event push --limit 5 \
  --json databaseId,headSha,status,conclusion,url
gh run watch <RUN_ID> --exit-status
```

On failure, inspect the failed step and report the root cause. Do NOT retry automatically.

### Step 6: Push and report

Ensure all commits are on the remote:
```bash
git push
```

Tell the user:
- Version released
- Link: `https://github.com/limboy/clearly/releases/tag/v<VERSION>`

## Important Rules

- ALWAYS confirm the version before proceeding
- NEVER tag a release if the working tree is dirty or `main` has not been pushed
- NEVER skip the changelog update
- If the GitHub Actions run fails, do NOT blindly retry. Report the error and stop. Retry is only okay after the root cause is identified and fixed (e.g., a bug in the script or a missing credential). Never retry on an unexplained or transient-looking failure without diagnosing it first.
- The tag-triggered GitHub Actions workflow is the canonical publishing path. `scripts/release.sh --dry-run` remains available for local build verification; do not run the local publishing path after pushing a release tag.
- Un-scoped commits (no `[mac]`/`[chore]` prefix) halt the release until resolved
