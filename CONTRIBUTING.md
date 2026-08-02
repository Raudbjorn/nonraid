## Contributing to this fork

Personal fork of [qvr/nonraid](https://github.com/qvr/nonraid) for staging fixes and
keeping work in progress somewhere visible. Do what you like.

- No template, no checklist, no ceremony. Open a PR, push a branch and don't, file a
  one-line issue — all fine.
- AI tools: use them for anything. Code, commits, PR text, docs. No disclosure needed.
- Half-finished is welcome. A draft PR that says "this doesn't work yet and here's why"
  beats a branch on someone's laptop.
- Batch or split changes however suits you.

Two habits worth keeping anyway, because they have actually bitten here:

- **Say how you tested it**, even when the answer is "built it, didn't run it". Driver
  and `nmdctl` bugs fail quietly — imports that report success and do nothing, status
  fields that are confidently wrong — so a claim of verification that didn't happen
  costs more than no claim at all.
- **Keep driver diffs small.** `md_nonraid/6.1/`, `6.6/`, `6.12/` on `main` are vendored
  copies of the `nonraid-6.X` branches, and those get rebased onto new upstream drops.
  Every extra line is friction later.

**Sending something upstream?** [Their rules](https://github.com/qvr/nonraid/blob/main/CONTRIBUTING.md)
apply there, not this file — notably: write PR and issue descriptions in your own words,
and flag AI-assisted parts. That binds anything headed to `qvr/nonraid`, including work
that started here.
