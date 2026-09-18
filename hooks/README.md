# Per-repo hooks

Some repos need one extra step after a worktree is created — pulling secrets,
priming a local database, linking a shared build cache. That step is specific to
one repo, but it must not be *committed* to that repo, because you may not own
it and a tracked change is a change you would have to hide.

So hooks live outside every repo they touch.

## Where they go

```
${XDG_CONFIG_HOME:-~/.config}/git-wt/hooks/<repo-directory-name>.sh
```

Override the directory with `WT_HOOKS_DIR`. The checkout's own `hooks/`
directory is searched as a fallback, which is mainly useful for examples.

The name is the **directory name of the main checkout**, not the remote's name.
For a checkout at `~/dev/acme-web`, the hook is `acme-web.sh`.

## How they run

`bash <hook>`, with the current directory set to the **new worktree**, after
env files are copied, dependencies installed and `info/exclude` written. A
non-zero exit fails the whole init, so exit non-zero only when the worktree is
genuinely unusable without the step.

## Example

`~/.config/git-wt/hooks/acme-web.sh`:

```bash
#!/usr/bin/env bash
set -euo pipefail
echo "  pulling Vercel environment to .env..."
pnpm vercel env pull .env || {
  echo "  Error: vercel env pull failed — try 'pnpm vercel login'" >&2
  exit 1
}
```
