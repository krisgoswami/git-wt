# git-wt

A git worktree helper that works in repos you do not own.

```
wt new feat/checkout     # create a worktree, install deps, carry over .env
wt checkout              # jump into it
wt clean --whatif        # see which worktrees have landed
wt clean                 # remove them, and the branches they pinned
```

Most worktree helpers are a thin wrapper around `git worktree add`. The three
things this does differently are the reason it exists.

## 1. It leaves no trace in the repo

Worktree paths are excluded through **`.git/info/exclude`**, never `.gitignore`.
`info/exclude` is read from the shared common git-dir, so one write covers every
worktree of the clone, it is never committed, and `git status` stays clean.

You can use this in a team repo, or a repo you have no write access to, without
producing a single tracked change you would have to remember to leave out of a
commit.

## 2. It knows two different ways work "lands"

`wt clean` removes a worktree when either signal fires, because neither one is
enough on its own:

- **`[gone]`** — the remote dropped the branch. This only ever appears if the
  branch had an upstream, so on a team that never pushes tracking branches it is
  permanently silent. It also fires for a **closed or rejected** PR whose commits
  never landed, so it is gated behind a `--days` window (default 7) and the
  branch is deleted with `git branch -d`, which refuses on unmerged commits.
- **Ancestry** — `git merge-base --is-ancestor <branch> origin/<default>`, which
  is proof the commits are in the default branch. No age window needed.

Tools that key off `[gone]` alone do nothing at all in a repo whose team keeps
branches after merge, and worktrees pile up silently.

**Known limitation:** a **squash merge** defeats the ancestry check, because it
rewrites the commits into a new SHA, and such a branch never goes `[gone]` if
the team keeps branches. There is no reliable automatic signal for squash-merged
branches. `wt clean` leaves them alone; remove those by hand.

## 3. It will not eat your uncommitted work

- `git worktree remove` is never `--force` by default. Dirty worktrees are kept
  and reported; `--force` is opt-in. Untracked files count as dirty — a stray
  `.env` or a build directory will stop a removal, and that is deliberate.
- New branches are created with **`--no-track`**. Branching off a remote-tracking
  ref otherwise makes git set it as the new branch's upstream, and with
  `push.default=upstream` a bare `git push` resolves to `<your-branch> -> main`:
  your commits, delivered straight onto the shared default branch. With
  `--no-track` there is no upstream, `git push` refuses, and it suggests
  `--set-upstream`, which creates a *new* remote branch.
- Branches are deleted with `-d`, not `-D`, wherever the merge state is not
  already proven.
- **The tool never touches the remote.** There is no `git push` anywhere in it.
  The only remote interaction is `git fetch --prune origin`, which is read-only
  on the remote. Deleting a remote branch stays a deliberate act by you.

---

## Install

```bash
git clone https://github.com/<you>/git-wt ~/.local/share/git-wt
~/.local/share/git-wt/install.sh
```

It symlinks `bin/git-wt` into `~/.local/bin` (so `git wt …` works) and prints
the one line to add to your rc file. It does not edit your rc file unless you
pass `--write-rc` — a tool that silently rewrites your shell config is one you
cannot audit.

```bash
. "$HOME/.local/share/git-wt/wt.sh"
```

Open a new shell, and `wt help` should answer.

**Which rc file?** The installer works it out, but the rule is worth knowing,
because getting it wrong looks exactly like the tool being broken:

| Shell | File |
|---|---|
| zsh | `~/.zshrc` — read by every interactive shell, on any OS |
| bash on Linux | `~/.bashrc` |
| bash on macOS | `~/.bash_profile` — Terminal.app opens a **login** shell for every window, and a login shell does not read `~/.bashrc` |

Requires bash or zsh, and git 2.17+. No other dependencies — no Python, no Node,
no package manager. It is shell scripts and git.

### Why `wt` is a shell function and `git wt` is a command

Jumping between worktrees has to change the **calling** shell's directory, and a
child process cannot do that to its parent. So `wt` is a sourced function.

`git wt` is a real executable, found by git's `git-<name>` subcommand lookup. It
does everything except jump; for that it offers `git wt path <substring>`, so
`cd "$(git wt path checkout)"` works from a script.

## Commands

| | |
|---|---|
| `wt` / `wt ls` | list every worktree |
| `wt <substring>` | jump to the worktree whose branch or path matches |
| `wt new <branch>` | create and initialise a worktree (alias: `create`) |
| `wt new <branch> --no-install` | …without installing dependencies |
| `wt clean [--whatif]` | remove worktrees whose work has landed |
| `wt clean --force` | also remove dirty ones, discarding the changes |
| `wt clean --days N` | how recent a `[gone]` branch must be (default 7) |
| `wt root` | jump back to the main checkout |
| `wt path <substring>` | print a worktree's path without jumping |

An ambiguous jump is not an error: it goes to the first match and prints the
rest. A detached-HEAD worktree is still reachable by path substring.

## Where worktrees live

One default, auto-detected, and one escape hatch.

| Condition | Worktree path |
|---|---|
| repo has a `.claude/` directory | `<repo>/.claude/worktrees/<branch>` |
| default | `<repo>/.worktrees/<branch>` |
| `WT_DIR` set to an absolute path | `<WT_DIR>/<repo-name>/<branch>` |

**Worktrees live inside the repo by default, and the dot prefix is load bearing.**

- **Hidden directories are skipped by most tooling.** Measured: ripgrep skips
  `.worktrees/` and descends into `worktrees/`. pytest's default
  `norecursedirs` is `*.egg .* _darcs build CVS dist node_modules venv {arch}`.
  ESLint and most file watchers follow the same convention. A non-dot directory
  inside the repo would give you duplicate search hits and doubled test
  collection in every project.
- **`includeIf "gitdir:…"` keeps matching.** Per-directory git identity is keyed
  by path. If your `~/.gitconfig` has an `includeIf gitdir:~/work/` rule setting
  your work email, a worktree at `~/work/repo/.worktrees/x` still matches it —
  and one at `~/worktrees/repo/x` silently does not, so you commit with the
  wrong email and find out in review. **This is the caveat on `WT_DIR`:** if you
  move worktrees outside the repo, add a matching `includeIf` rule for the new
  location.
- `info/exclude` keeps the directory invisible to git without touching the repo.

`.claude/worktrees/` is auto-detected because that exact path is what Claude
Code's worktree entry treats as pre-approved. If you use Claude Code you get it
with no configuration; if you do not, you never see it. The Claude-specific
exclude entries are only written in that mode.

Override with the environment or with git config:

```bash
export WT_DIR=~/worktrees            # external layout, all repos
git config wt.dir ~/worktrees        # external layout, this repo
git config wt.layout default         # force <repo>/.worktrees even with .claude/
```

## What `wt new` does

1. `git fetch origin`, then branches off the **default branch resolved from
   `origin/HEAD`** — never assumed to be `main`. Many clones have `origin/HEAD`
   unset, so it falls back to `origin/main`, `origin/master`, `origin/develop`,
   then warns and tells you to run `git remote set-head origin --auto`.
2. `git worktree add --no-track -b <branch> <base>` (see above).
3. Copies local-only files the main checkout has and a fresh worktree cannot:
   `.env`, `.env.local`, `.env.development.local`, `.envrc`, `.tool-versions`.
   Never clobbers one that already exists, and never copies a file git tracks.
   Override the list with `WT_ENV_FILES`.
4. Installs dependencies, detected from lockfiles:

   | Ecosystem | Detected from | Runs |
   |---|---|---|
   | Node | `pnpm-lock.yaml`, `yarn.lock`, `bun.lockb`/`bun.lock`, `package-lock.json` | `pnpm install --frozen-lockfile`, `yarn install --frozen-lockfile`, `bun install --frozen-lockfile`, `npm ci` |
   | Deno | `deno.lock` | `deno install` |
   | Python | `uv.lock`, `poetry.lock`, `Pipfile.lock` | `uv sync`, `poetry install`, `pipenv sync` |
   | Rust | `Cargo.lock` | `cargo fetch` |
   | Go | `go.mod` | `go mod download` |
   | Ruby | `Gemfile.lock` | `bundle install` |
   | PHP | `composer.lock` | `composer install` |
   | Elixir | `mix.lock` | `mix deps.get` |
   | .NET | `*.sln`, `*.csproj`, `*.fsproj` | `dotnet restore` |
   | Gradle | `gradlew` | `./gradlew --quiet --no-daemon dependencies` |
   | Maven | `pom.xml` | `mvn -q -B dependency:go-offline` |

   Alternatives within one ecosystem are first-match-wins; ecosystems are
   independent, so a polyglot repo gets each one. A tool that is not on `PATH`
   is skipped with a warning, and a failed install never fails the worktree.
   Skip the whole step with `--no-install` or `WT_NO_INSTALL=true`.
5. Writes the exclude entries into `.git/info/exclude`.
6. Runs the per-repo hook, if you have one. See [`hooks/README.md`](hooks/README.md).

If `git worktree add` fails it prunes and rolls back — deleting the branch only
if this run created it, never a branch that already existed.

## What `wt clean` does not do

- It never touches the remote.
- It skips the worktree you are standing in. (Removing the directory your shell
  is sitting in leaves it with a deleted cwd, and every later command fails with
  `getcwd: cannot access parent directories`.)
- It skips the main checkout and the default branch.
- It skips detached-HEAD worktrees.
- It refuses to run at all if it cannot resolve a default branch, rather than
  guessing `main` and deleting against the wrong baseline.

Removing a worktree does **not** delete its branch, and a branch cannot be
deleted while a worktree holds it (`error: cannot delete branch 'X' used by
worktree at …`). So a stale worktree pins a stale branch, and `wt clean` handles
the pair together.

## Configuration

| | |
|---|---|
| `WT_DIR` | absolute path; switches to the external layout |
| `WT_LAYOUT` | `claude` \| `default` \| `external` — force a layout |
| `WT_ENV_FILES` | space-separated list of local-only files to carry over |
| `WT_NO_INSTALL` | `true` to skip dependency installation |
| `WT_HOOKS_DIR` | where per-repo hooks live (default `~/.config/git-wt/hooks`) |
| `WT_GONE_DAYS` | default for `clean --days` |

`wt.dir` and `wt.layout` also work as `git config` keys, for per-repo settings.

## License

MIT
