# Per-repo hooks

Some repos need one extra step when a worktree is created — fetching vendored
files, pulling secrets, priming a local database, linking a shared build cache.
That step is specific to one repo, but it must not be *committed* to that repo,
because you may not own it and a tracked change is a change you would have to
hide.

So hooks live outside every repo they touch.

## Two hooks, and why

| Hook | Runs | Use it for |
|---|---|---|
| `<repo>.pre.sh` | after env files are copied, **before** dependencies install | files the install itself needs |
| `<repo>.sh` | last, after dependencies install and `info/exclude` is written | steps that need the installed dependencies |

One hook can't serve both. A step like `pnpm vercel env pull` needs
`node_modules`, so it has to run after the install. A repo whose lockfile points
at a gitignored path, such as `[tool.uv.sources] pkg = { path = "vendor/pkg" }`,
needs that path filled in *before* `uv sync`, or the install fails. A failed
install only prints a warning, so without a pre-install hook you get a worktree
that looks ready but has no dependencies.

Both hooks are optional, and you can have either, both or neither.

## Where they go

```
${XDG_CONFIG_HOME:-~/.config}/git-wt/hooks/<repo-directory-name>.pre.sh
${XDG_CONFIG_HOME:-~/.config}/git-wt/hooks/<repo-directory-name>.sh
```

Override the directory with `WT_HOOKS_DIR`. The checkout's own `hooks/`
directory is searched as a fallback, which is mainly useful for examples.

The name is the **directory name of the main checkout**, not the remote's name.
For a checkout at `~/dev/acme-web`, the hooks are `acme-web.pre.sh` and
`acme-web.sh`.

## How they run

`bash <hook>`, with the current directory set to the **new worktree**.

- `<repo>.pre.sh` runs after env files are copied (so it can read `.env`) and
  before dependencies install. It still runs with `--no-install`, because it
  fetches files the worktree needs. It doesn't install packages.
- `<repo>.sh` runs after env files are copied, dependencies installed and
  `info/exclude` written.

A non-zero exit from either fails the whole init, so exit non-zero only when the
worktree is genuinely unusable without the step.

## Examples

`~/.config/git-wt/hooks/acme-api.pre.sh` runs the repo's own fetch script, so
the gitignored `vendor/` path dependency exists before `uv sync`:

```bash
#!/usr/bin/env bash
set -euo pipefail
echo "  fetching vendored packages..."
bash scripts/fetch-vendor.sh
```

`~/.config/git-wt/hooks/acme-web.sh` needs `node_modules`, so it runs after the
install:

```bash
#!/usr/bin/env bash
set -euo pipefail
echo "  pulling Vercel environment to .env..."
pnpm vercel env pull .env || {
  echo "  Error: vercel env pull failed — try 'pnpm vercel login'" >&2
  exit 1
}
```
