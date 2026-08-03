## Contributing to this fork

Personal fork of [qvr/nonraid](https://github.com/qvr/nonraid) for staging fixes and
keeping work in progress somewhere visible. Do what you like.

- No template, no checklist, no ceremony. Open a PR, push a branch, or file a
  one-line issue — all fine.
- AI tools: use them for anything. Code, commits, PR text, docs. No disclosure needed.
- Half-finished is welcome. A draft PR that says "this doesn't work yet and here's why"
  beats a branch on someone's laptop.
- Batch or split changes however suits you.

**One-time setup:** `git config core.hooksPath .githooks`. GitHub Actions is
*deliberately disabled* on this fork; the scripts under `checks/` are the CI,
and the hooks are what run them:

- `pre-commit` applies mechanical fixes to what you are committing (trailing
  whitespace, final newline, exec bit on shebang scripts) — vendored driver
  copies and the `tools/debian` unit copies are never touched.
- `pre-push` runs `checks/fast.sh` always (~12s), and the docker-based
  package + PVE lifecycle tiers when the push touches what they cover. First
  heavy run builds a container image (~5 min); after that, tens of seconds.

Escapes: `NONRAID_PUSH_FAST=1 git push` skips the docker tiers loudly;
`git push --no-verify` skips everything, for emergencies.

Two habits worth keeping anyway, because they have actually bitten here:

- **Driver fixes start on the matching `nonraid-6.X` branch**, not on `main`.
  `md_nonraid/6.1/`, `6.6/` and `6.18/` on `main` are vendored copies; a fix
  made only there is lost the next time those copies are refreshed from the
  branch. Land it on `nonraid-6.X`, then copy it across.

- **Say how you tested it**, even when the answer is "built it, didn't run it". Driver
  and `nmdctl` bugs fail quietly — imports that report success and do nothing, status
  fields that are confidently wrong — so a claim of verification that didn't happen
  costs more than no claim at all.
- **Keep driver diffs small.** `md_nonraid/6.1/`, `6.6/`, `6.18/` on `main` are vendored
  copies of the `nonraid-6.X` branches, and those get rebased onto new upstream drops.
  Every extra line is friction later.

**Sending something upstream?** [Their rules](https://github.com/qvr/nonraid/blob/main/CONTRIBUTING.md)
apply there, not this file. Two in particular, because they are the opposite of the line
above: **do not generate PR or issue descriptions with AI** — write them yourself — and
disclose any AI-assisted parts of the contribution. That binds anything headed to
`qvr/nonraid`, including work that started here.
