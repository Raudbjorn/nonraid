## Contributing to this fork

This is a personal fork of [qvr/nonraid](https://github.com/qvr/nonraid). It exists to
stage fixes, try things out, and keep work-in-progress somewhere visible. Rules here are
deliberately light.

**If you want to contribute to NonRAID itself, go upstream** — that's where the project
lives, and [upstream's CONTRIBUTING](https://github.com/qvr/nonraid/blob/main/CONTRIBUTING.md)
applies there, not this file. In particular upstream asks that pull request and issue
descriptions be written in your own words rather than generated, and that AI-assisted
contributions say so. Those rules still bind anything sent to `qvr/nonraid`, including
work that started life on this fork.

### Here, though

Open a PR. Or push a branch and don't. Or open an issue that's one sentence. All fine.

- **No template, no checklist.** A title and enough context to know what you were going
  for is plenty. If the diff is self-explanatory, say so and move on.
- **Batch changes if you like.** Separate PRs per concern are easier to review, so prefer
  that when it's natural — but a grab-bag branch is not going to be turned away.
- **AI tools: use whatever you want**, for code, commits, PR text, docs. No disclosure
  needed. The one thing worth caring about is that *someone* understood the change before
  it landed — a fix nobody can explain is a liability regardless of who or what wrote it.
- **Work in progress is welcome.** Draft PRs, half-finished branches, "this doesn't work
  yet and here's why" — all more useful sitting here than on a laptop.
- **Docs changes need no ceremony.** Fix the typo, restructure the section, whatever.

### Things worth keeping

Not rules, just the stuff that has actually bitten:

- **Say how you tested it**, even if the answer is "I didn't". Driver and `nmdctl` bugs
  tend to fail silently — an import that reports success and does nothing, a status field
  that's confidently wrong. "Built, didn't run it" is a useful sentence; a claim of
  verification that didn't happen is worse than no claim.
- **Driver source lives on the `nonraid-6.X` branches.** `md_nonraid/6.1/`, `6.6/` and
  `6.12/` on `main` are vendored copies. A driver change usually belongs on the matching
  branch and gets copied across; patching the copy on `main` works but drifts.
- **Keep driver diffs small.** The `nonraid-6.X` branches are rebased onto new upstream
  vendor drops, and every extra line is friction at rebase time. This is the one place
  where restraint pays for itself.
- **CI gates `shellcheck -x tools/nmdctl` and `bash -n`.** Both are instant locally; run
  them and skip a round trip. `cd tools && bats tests/` covers the pure functions.
- **Rebasing on upstream `main` before sending anything onward** saves an awkward PR that
  appears to revert work already merged there.

That's it. If in doubt, just do the thing.
