# Contributing

Thanks for considering a contribution to this project.

## Making changes

- Fork, branch off `main`, one logical change per PR.
- Follow the script conventions in `AGENTS.md`: SPDX header, `set -euo
  pipefail`, `cd "$(dirname "${BASH_SOURCE[0]}")"`, the `pg-`/`mb-` naming
  prefix, comments that explain *why* not *what*.
- New files should carry `# SPDX-License-Identifier: AGPL-3.0-only`,
  matching `LICENSE`.

## Testing your change

There's no CI. Before opening a PR:
- Run the change locally end to end (`./setup.sh`, exercise the behavior).
- If it touches backup/restore, run `test/pg-backup.sh` or
  `test/mb-backup.sh` against a disposable stack — they're destructive.
- Say in the PR description what you tested and how, since there's no
  automated check to point to instead.

## Secrets

Never commit or paste into a PR/issue the contents of `.env`,
`extra-users.conf`, `pg-config/`, or `pgadmin-config/` — they're gitignored
because they hold generated passwords. Redact them if your terminal output
includes one.

## Pull requests

- Keep PRs focused; fold in unrelated cleanups only if trivial, otherwise
  split them out.
- Update `README.md`/`AGENTS.md` in the same PR if you change documented
  behavior.
- Reviews may be done by an AI agent (Claude) working from `AGENTS.md`'s
  conventions — following them reduces back-and-forth.

## License

By contributing, you agree your contribution is licensed under
AGPL-3.0-only, same as the rest of the repo.
