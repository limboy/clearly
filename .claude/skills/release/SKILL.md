---
name: release
description: Determine the next version, update the marketing site, and run the full Mac release pipeline.
---

Cut a new Mac release of Clearly. See `CLAUDE.md` "Versioning" and "Commit message rule". This skill derives the version from the Mac tag history and runs the release pipeline.

## Instructions

### Step 1: Verify prerequisites

1. `.env` exists at the project root. If not, stop and tell the user:
   "Missing `.env` file. Copy `.env.example` to `.env` and fill in APPLE_TEAM_ID, APPLE_ID, and SIGNING_IDENTITY_NAME."
2. `notarytool` keychain profile `AC_PASSWORD` works. If not, stop and tell the user to run:
   ```bash
   xcrun notarytool store-credentials "AC_PASSWORD" --apple-id "$APPLE_ID" --team-id "$APPLE_TEAM_ID" --password "<app-specific-password>"
   ```
3. Working tree clean (`git status --porcelain`). If dirty, stop and ask the user to commit or stash.
4. On the `main` branch. If not, stop.

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
2. Edit `website/index.html`. Update the `class="requires"` line — match the existing minimum-macOS wording, do not hardcode a name:
   ```html
   <p class="requires">v<VERSION> &middot; Requires macOS Sequoia or later</p>
   ```
3. Commit:
   ```bash
   git add project.yml website/index.html CHANGELOG.md
   git commit -m "[mac] Update marketing site version to v<VERSION>"
   git push
   ```

### Step 5: Run the release script

```bash
./scripts/release.sh <VERSION>
```
Handles: xcodegen → archive → export → DMG → notarize → staple → git tag `v<VERSION>` → appcast → push → GitHub Release.

Let the script run to completion. On failure, report the error and stop. Do NOT retry automatically.

### Step 6: Push and report

Ensure all commits are on the remote:
```bash
git push
```

Tell the user:
- Version released
- Link: `https://github.com/Shpigford/clearly/releases/tag/v<VERSION>`

## Important Rules

- ALWAYS confirm the version before proceeding
- NEVER run a release script if `.env` is missing or the working tree is dirty
- NEVER skip the changelog update
- If the release script fails, do NOT blindly retry. Report the error and stop. Retry is only okay after the root cause is identified and fixed (e.g., a bug in the script, a missing credential, a stale file). Never retry on an unexplained or transient-looking failure without diagnosing it first.
- The release scripts handle git tagging — do not duplicate those steps
- Un-scoped commits (no `[mac]`/`[chore]` prefix) halt the release until resolved
