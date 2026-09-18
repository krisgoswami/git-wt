# git-wt

Worktrees without the setup tax — so you can run several coding agents at once.

One checkout means one branch at a time, which caps you at one agent at a time.
Git worktrees lift the cap: several branches checked out at once, in separate
directories, sharing one clone's objects. One agent per directory.

With Claude Code the separation runs deeper than the files — a session belongs to
its directory, so every worktree keeps its own conversation instead of piling
six features into one history.

What's left is friction: a new worktree has no `.env`, no dependencies, and it
litters `git status`. This removes it.

```bash
wt new feat/checkout     # create it, install deps, carry over .env
wt checkout              # jump into it
wt clean --whatif        # see which ones have landed
wt clean                 # remove them, and the branches they pinned
```

Most worktree helpers wrap `git worktree add`. Three things here are different.

**1. It leaves no trace in the repo.** Worktree paths are excluded through
`.git/info/exclude`, never `.gitignore` — one write covers every worktree of the
clone, it is never committed, and `git status` stays clean. Safe in a team repo,
or one you have no write access to.

**2. It knows two different ways work "lands".** `wt clean` removes a worktree
when either signal fires, because neither is enough alone:

- **`[gone]`** — the remote dropped the branch. Silent on teams that never push
  tracking branches, and it also fires for *closed* PRs whose commits never
  landed, so it is gated behind `--days` (default 7) and deleted with
  `git branch -d`, which refuses on unmerged commits.
- **Ancestry** — `git merge-base --is-ancestor`, proof the commits are in the
  default branch. No age window needed.

Tools keying off `[gone]` alone do nothing in a repo that keeps merged branches.
*Known limitation:* a **squash merge** defeats the ancestry check and never goes
`[gone]`. There is no reliable signal for those; `wt clean` leaves them alone.

**3. It will not eat your uncommitted work.**

- `wt clean --whatif` previews the whole run as `would: …` lines and changes
  nothing. Reach for it first.
- Never `--force` by default. Dirty worktrees are kept and reported, and
  untracked files count as dirty — deliberately.
- New branches use `--no-track`, so a bare `git push` can't resolve to
  `<your-branch> -> main` under `push.default=upstream` and deliver your commits
  onto the shared default branch.
- Branches are deleted with `-d`, not `-D`, wherever merge state isn't proven.
- **It never touches the remote.** The only remote call is `git fetch --prune`.

## Install

Nothing goes on your PATH. `wt` is a shell function, so installing it means
sourcing one file from your rc — that is the whole install.

```bash
git clone https://github.com/krisgoswami/git-wt.git ~/.local/share/git-wt
```

Then add this line to your rc file, open a new shell, and `wt help` should
answer:

```bash
. "$HOME/.local/share/git-wt/wt.sh"
```

Clone it somewhere permanent — the rc line points at the clone. Running
`install.sh` is optional: it works out which rc file your shell actually reads
and prints the line, or appends it with `--write-rc`.

**Which rc file?** Getting it wrong looks exactly like the tool being broken:

| Shell | File |
|---|---|
| zsh | `~/.zshrc` — every interactive shell, any OS |
| bash on Linux | `~/.bashrc` |
| bash on macOS | `~/.bash_profile` — Terminal.app opens a **login** shell per window, and login shells skip `~/.bashrc` |

Requires bash or zsh and git 2.17+. No other dependencies.

**Not for native Windows.** `wt` is a bash/zsh function, so PowerShell and CMD
cannot run it at all. On Windows use **WSL**, where this works unchanged — WSL is
Linux, and it is the only Windows setup tested. Keep the repo on the WSL
filesystem (`~/code/...`), not `/mnt/c/...`, where git and installs crawl.

This is a limit of the wrapper, not of worktrees. `git worktree add|list|remove`
is native git and works fine in PowerShell — you just do the jumping and the
`.env` copying yourself.

**Why a shell function?** Jumping worktrees has to change the *calling* shell's
directory, which no child process can do to its parent. The tradeoff: a function
only exists in a shell that sourced it, so `wt` is unavailable in scripts and CI.
For those, call the underlying scripts directly — same arguments:

```bash
~/.local/share/git-wt/lib/make-worktree.sh feat/checkout
~/.local/share/git-wt/lib/cleanup-worktrees.sh --whatif
```

## Commands

| | |
|---|---|
| `wt` / `wt ls` | list every worktree |
| `wt <substring>` | jump to the worktree whose branch or path matches |
| `wt new <branch>` | create and initialise a worktree (alias: `create`) |
| `wt new <branch> --no-install` | …without installing dependencies |
| `wt clean` | remove worktrees whose work has landed |
| `wt clean --whatif` | preview it, change nothing (alias: `--dry-run`) |
| `wt clean --force` | also remove dirty ones, discarding changes |
| `wt clean --days N` | how recent a `[gone]` branch must be (default 7) |
| `wt root` | jump back to the main checkout |
| `wt path <substring>` | print a worktree's path without jumping |

An ambiguous jump goes to the first match and prints the rest. Detached-HEAD
worktrees are still reachable by path substring.

## Where worktrees live

| Condition | Path |
|---|---|
| repo has a `.claude/` directory | `<repo>/.claude/worktrees/<branch>` |
| default | `<repo>/.worktrees/<branch>` |
| `WT_DIR` set to an absolute path | `<WT_DIR>/<repo-name>/<branch>` |

Worktrees live inside the repo, and **the dot prefix is load bearing**: hidden
directories are skipped by ripgrep, pytest's `norecursedirs`, ESLint and most
watchers. A non-dot directory would give you duplicate search hits and doubled
test collection in every project.

**The caveat on `WT_DIR`:** per-directory git identity via `includeIf "gitdir:…"`
is keyed by path. A worktree at `~/work/repo/.worktrees/x` still matches an
`includeIf gitdir:~/work/` rule; one at `~/worktrees/repo/x` silently does not,
so you commit with the wrong email. Move worktrees out, add a matching rule.

`.claude/worktrees/` is auto-detected because that exact path is what Claude
Code treats as pre-approved. Override:

```bash
export WT_DIR=~/worktrees            # external layout, all repos
git config wt.dir ~/worktrees        # external layout, this repo
git config wt.layout default         # force <repo>/.worktrees even with .claude/
```

## What `wt new` does

1. Fetches, then branches off the default branch **resolved from `origin/HEAD`**
   — never assumed to be `main`. Falls back to `origin/main`, `master`,
   `develop`, then warns to run `git remote set-head origin --auto`.
2. `git worktree add --no-track -b <branch> <base>`.
3. Copies local-only files a fresh worktree can't have: `.env`, `.env.local`,
   `.env.development.local`, `.envrc`, `.tool-versions`. Never clobbers an
   existing file, never copies a tracked one. Override with `WT_ENV_FILES`.
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

   First match wins within an ecosystem; a polyglot repo gets each one. A tool
   not on `PATH` is skipped with a warning, and a failed install never fails the
   worktree. Skip with `--no-install` or `WT_NO_INSTALL=true`.
5. Writes the exclude entries, then runs the per-repo hook if you have one — see
   [`hooks/README.md`](hooks/README.md).

If `git worktree add` fails it prunes and rolls back, deleting the branch only if
this run created it.

## What `wt clean` skips

The worktree you are standing in (removing it leaves your shell with a deleted
cwd), the main checkout, the default branch, and detached-HEAD worktrees. It
refuses to run at all if it cannot resolve a default branch, rather than guessing
`main` and deleting against the wrong baseline.

Removing a worktree does not delete its branch, and a branch can't be deleted
while a worktree holds it — so a stale worktree pins a stale branch, and
`wt clean` handles the pair together.

## Configuration

| | |
|---|---|
| `WT_DIR` | absolute path; switches to the external layout |
| `WT_LAYOUT` | `claude` \| `default` \| `external` — force a layout |
| `WT_ENV_FILES` | space-separated local-only files to carry over |
| `WT_NO_INSTALL` | `true` to skip dependency installation |
| `WT_HOOKS_DIR` | where per-repo hooks live (default `~/.config/git-wt/hooks`) |
| `WT_GONE_DAYS` | default for `clean --days` |

`wt.dir` and `wt.layout` also work as `git config` keys, for per-repo settings.

## License

MIT
