---
name: finish-release
description: |
  Finishes a release from its open release-prep PR (from /prep-release):
  squash-merges that PR, creates and pushes the annotated vX.Y.Z tag on the
  merge commit, then publishes the GitHub release notes. Pushing the tag
  triggers the Publish workflow (RubyGems Trusted Publishing), so this is the
  step that ships the gem. Use when the user types /finish-release, asks to
  "merge and tag the release", "publish the release notes", "ship v0.x.y", or
  has just reviewed the release-prep PR.
user_invocable: true
version: 1.0.0
---

# Finish Release

The counterpart to `/prep-release`. That skill stops at an open release PR and
never merges, tags, or publishes; this one starts after the user has reviewed
that PR. **Invoking `/finish-release` is the user's authorization to merge that
PR, tag, and publish** (`AGENTS.md` names this as the one sanctioned path).
Order: **preconditions, merge, tag, release notes, report**. The release is
created with `--verify-tag`, so the tag has to exist first.

**What pushing the tag does:** `.github/workflows/publish.yml` runs on any
`v*.*.*` tag push. The build job runs RSpec and RuboCop, builds the gem, and
checks the tag matches `Squishling::AppleFM::VERSION`. The publish job then
ships to RubyGems via Trusted Publishing behind the `rubygems-publish`
environment; if that environment has a required reviewer, the job waits for the
user's approval in the Actions UI. The Swift helper is not compiled by the
publish workflow: `/prep-release` validated it on a Mac, and CI's macOS job
checks it on every PR.

## Phase 1: Preconditions (abort on any failure, change nothing)

1. Find the release PR: `gh pr list --state open --search "chore: release in:title"
   --json number,title,headRefName,isDraft,mergeable,mergeStateStatus,body`. Its
   head branch is `release/vX.Y.Z` (per `/prep-release`) and its title
   `chore: release vX.Y.Z`. Zero or several matches: stop and ask. **Resume:**
   if no PR is open but one is merged (`--state merged`) and `origin/main` has
   the version with no tag, the user merged it by hand; skip Phase 2 and use
   its merge commit. If the tag already exists but no release does, skip to
   Phase 4 after confirming the tag points at the merge commit.
2. `git fetch origin main <head branch> --tags`. Read `X.Y.Z` from the PR head,
   not the working tree:
   `git show origin/<branch>:lib/squishling/apple_fm/version.rb`. The tag is
   `vX.Y.Z`.
3. Check all of these, and stop and tell the user which one failed:
   - `X.Y.Z` is greater than the latest tag (`git describe --tags --abbrev=0
     origin/main`). No tag yet means this is the first release: any version is
     fine, and Phase 4 has no previous release to copy from.
   - On the PR head, `CHANGELOG.md` has a `## [X.Y.Z] - <date>` heading and
     `Gemfile.lock` has `squishling-apple_fm (X.Y.Z)`. CI installs the lockfile
     frozen, so a stale one is a bad release. The gemspec's `squishling`
     requirement names a released Squishling and the `Gemfile` has no `github:`
     source for it (`/prep-release` Phase 3 step 6).
   - The PR is open, not a draft, `mergeable` and `mergeStateStatus` is `CLEAN`.
     Don't rely on a green merge button alone: run `gh pr checks <n>` and
     require every check (the Ruby matrix, RuboCop, exhale, the gem build, and
     the macOS Swift job) to be passing, not pending.
   - The PR body does not flag unfinished validation. `/prep-release` writes the
     live-example result there, and a release PR can say it was "NOT run"
     because the machine had no Apple Intelligence. If so, show the user and
     confirm before merging.
   - The tag does not exist locally (`git tag -l vX.Y.Z`) or on the remote
     (`git ls-remote --tags origin 'vX.Y.Z*'`), and `gh release view vX.Y.Z`
     fails.
   - **The publish path works.** Check
     `gh api repos/Coolhand-Labs/squishling-apple-fm-adapter/environments` lists
     `rubygems-publish`. If the gem isn't on RubyGems yet
     (`gem search -e squishling-apple_fm --remote` is empty), this is its first
     publish, and a trusted publisher that creates a new gem must name the
     RubyGems account that will own it (the `owner` parameter of the OIDC token
     exchange, shown as an account ID on the pending publisher's page). Check
     whether the `rubygems/release-gem` version pinned in `publish.yml` has an
     `owner` input (`action.yml` at that SHA) and whether `publish.yml` passes
     it. If it doesn't, the tag would start a Publish run that RubyGems rejects:
     stop and ask the user whether they are publishing the first version by hand
     (`gem push`, then adding a normal trusted publisher on the gem's page), in
     which case the Publish run on the tag will fail harmlessly because the
     version already exists, or whether they want the workflow changed first.
     Don't tag until they answer.

## Phase 2: Merge the release PR

1. Save the PR's current description outside the repo:
   `gh pr view <n> --json body --jq .body > "$TMPDIR/apple-fm-release-pr-<n>.md"`.
2. `gh pr merge <n> --squash --delete-branch --subject "release vX.Y.Z (#<n>)"
   --body-file "$TMPDIR/apple-fm-release-pr-<n>.md"`. The commit title drops
   the PR's `chore:` prefix (`--subject` is used verbatim, so keep the `(#N)`
   suffix), with the PR body as the commit body verbatim. Add no AI attribution
   (`AGENTS.md`). Never `--admin`, never bypass a check. If the merge is
   refused, stop and report. If `--delete-branch` can't delete the local branch
   because a worktree has it checked out, the merge still happened: confirm with
   `gh pr view <n> --json state` and carry on.
3. `git fetch origin main --tags`. Take the merge commit from
   `gh pr view <n> --json mergeCommit` and confirm
   `git show <sha>:lib/squishling/apple_fm/version.rb` still says `X.Y.Z`.

## Phase 3: Tag

1. `git tag -a vX.Y.Z <merge commit sha> -m "vX.Y.Z"`. Tag the merge commit, not
   `origin/main` HEAD, so the gem ships exactly what `/prep-release` validated
   even if other PRs landed since. Annotated, so it records who tagged and when.
2. `git push origin refs/tags/vX.Y.Z`. Push only that ref, never `--tags`. If a
   tag ruleset blocks the push, the user must be on its bypass list: report it,
   don't work around it.
3. Verify with `git ls-remote --tags origin 'vX.Y.Z*'`. The `git push` output
   can be swallowed by the shell's output filter, so don't trust its silence;
   the `^{}` line must show the merge commit.

Never `rake release` or `gem push`; CI publishes.

## Phase 4: Release notes

1. **Format template.** If a previous release of this gem exists, fetch it:
   `gh release view v<previous> --json body --jq .body`, and match its structure
   and tone. For the first release there is none, so use Squishling's latest
   (`gh release view --repo Coolhand-Labs/squishling --json body --jq .body`) as
   the model and adapt it: `## 🚀 What's New` (a one-paragraph summary in
   bold-keyword style, then the install snippet and a `Requires` line), then
   `---`-separated emoji sections: `## ⚠️ Upgrading from <previous>` first when
   anything breaks or changes behavior (omit on the first release), one per
   feature, `## 🔒 Security` (or `Security and Fixes`), `## ⚠️ Worth Knowing`,
   `## 🔗 Resources` (Documentation, Changelog, RubyGems). Keep only sections
   with content. The install snippet is
   `gem "squishling-apple_fm", group: :development` next to
   `gem "squishling"`, with a `~> X.Y` form if the notes recommend one.
   Re-derive the `Requires` line from the gemspec and README at the tag: Ruby,
   macOS 26+ on Apple Silicon with Apple Intelligence on, Xcode or its Command
   Line Tools, and the Squishling release.
2. Source the content from the `## [X.Y.Z]` CHANGELOG section and the merged
   PRs since the previous tag (`git log v<previous>..vX.Y.Z --oneline`; the whole
   history on a first release), reading the PRs and the diff for anything the
   changelog compresses. Write for users: what it does, a short code example for
   new API or options, and a before/after snippet for anything
   behavior-affecting. Use full
   `https://github.com/Coolhand-Labs/squishling-apple-fm-adapter/...` URLs (blob
   links to `main` for docs), not relative links.
3. **Verify every claim and every issue link before publishing.** For Worth
   Knowing, take the issues from the previous release (on a first release, the
   open issues the changelog and PR body point at, and the limits the README
   lists) and run `gh issue view <n> --json state` on each: drop closed ones, and
   re-read any issue the release touches (partly fixed counts as still open, with
   a parenthetical saying what was fixed). Don't describe a behavior you haven't
   read in the code or the PR.
4. Write the notes outside the repo, e.g. `$TMPDIR/apple-fm-release-notes-vX.Y.Z.md`
   (never commit the file).
5. `gh release create vX.Y.Z --verify-tag --title "vX.Y.Z" --notes-file
   <that file> --latest`. Not a draft and not a prerelease. Confirm with
   `gh release view vX.Y.Z --json name,tagName,isDraft,url`.

## Phase 5: Report

State, in the final message:
- The merged PR number and its merge commit, and the tag pointing at it.
- The release URL.
- The Publish workflow run (`gh run list --workflow publish.yml --limit 1`) and
  whether the build job passed and the publish job is waiting for the
  `rubygems-publish` approval (or why it failed). Do not approve, re-run, or
  publish by any other route. Check the run again later if the user asks whether
  the gem is live (`gem search -e squishling-apple_fm --remote`, or the RubyGems
  page).
- On a first release, anything the user still has to do on RubyGems or GitHub
  for later releases to publish from CI.

## Rationalizations to resist

- *"The version file on my branch says X.Y.Z, close enough."* Read it from the
  PR head, then from the merge commit. A stale checkout publishes the wrong code.
- *"Checks are probably green."* Run `gh pr checks`. Nothing else gates the
  merge unless `main` has a ruleset, and even then read the checks.
- *"I'll use the default squash message."* The title and body are the permanent
  record of the release; pass `--subject` and `--body-file`.
- *"`main` has moved on, I'll just tag HEAD."* The release PR was validated at
  its merge commit; HEAD may carry unreviewed changes.
- *"I'll publish the notes first and tag after."* Without a tag, GitHub makes
  one itself from the branch tip, unannotated and unreviewed.
- *"The old Worth Knowing list is fine."* Issues get closed. Check each one.
- *"`git push` printed nothing, so it worked."* Verify with `git ls-remote`.
- *"It's the first release, the publish workflow will just work."* A new gem's
  first trusted publish has extra requirements. Check them before the tag exists,
  because a pushed tag can't be quietly taken back.
