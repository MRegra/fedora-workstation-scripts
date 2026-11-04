# ADR 0002: shared Renovate preset lives in this public repo

- Status: accepted (PR #9, merged 2026-10-25)
- Context item: F-2114 (docs pass; decision itself was made in PR #9)

## Context

Several of the owner's repos are moving from Dependabot version updates to
Renovate. Rather than duplicate the same policy (scheduling, grouping,
automerge rules, vulnerability-alert handling) in every repo, the owner
wants one shared preset that each consumer extends with a single line:

```json
"extends": ["github>MRegra/fedora-workstation-scripts//renovate/default"]
```

The preset must be readable by every consumer's `RENOVATE_TOKEN`. Those
tokens are fine-grained PATs scoped to one repo each, and a fine-grained PAT
can always read public repos regardless of which repo it's scoped to. So the
preset has to live in a repo that is public.

## Decision

Put the preset at `renovate/default.json` in `fedora-workstation-scripts`
(this repo), which is already public. Renovate itself stays **disabled** on
this repo — no consumer `renovate.json` here, no Renovate bot config for
this repo's own dependencies. The file exists purely to be `extends`-ed by
other repos.

This repo was chosen because it's the most neutral public repo the owner
already controls, not because the preset is topically related to Fedora
workstation scripts. A dedicated public `MRegra/renovate-config` repo would
be a cleaner home.

## Consequences

- One edit to `renovate/default.json` changes dependency-update policy for
  every consumer in one place.
- This repo now carries a config file unrelated to its stated purpose
  (Fedora workstation maintenance scripts). `CLAUDE.md` and `README.md` call
  this out explicitly so it doesn't read as stray/orphaned config.
- If the owner creates a dedicated `MRegra/renovate-config` repo later, each
  consumer's `extends` line needs updating; the preset content itself can
  move unchanged.
- Rollback: revert PR #9 and change each consumer back to its own inline
  Renovate config (or back to Dependabot).
