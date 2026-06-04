# Worktrees

RepoPrompt CE can create Git worktrees for MCP tools and Agent Mode. For app-managed worktrees, you can ask RepoPrompt to copy selected local files that are useful for development but should not be committed.

The common example is a local environment file:

```text
main checkout has .env.local
RepoPrompt creates .repoprompt-worktrees/my-repo-agent
RepoPrompt copies .env.local into the new worktree
agent starts with the same local setup
```

## Copying local ignored files with `.worktreeinclude`

Create a file named `.worktreeinclude` at the repository root of your main checkout.

RepoPrompt reads that file when it creates a new app-managed worktree. The file uses `.gitignore` syntax: one pattern per line, `#` comments, directory patterns, globs, and `!` negation patterns work the same way they do in `.gitignore`.

Only files that pass both checks are copied:

1. Git already treats the file as ignored, using the repository's normal ignore rules.
2. The file matches `.worktreeinclude` with a positive final match.

That means tracked files are not copied from your dirty working tree, and ordinary untracked files are not copied just because they match `.worktreeinclude`. The file must already be Git-ignored.

## Example

```gitignore
# .gitignore
.env.local
config/secrets.json
certs/local/
```

```gitignore
# .worktreeinclude
.env.local
config/secrets.json
certs/local/
certs/local/**

# Keep this one out even though the directory is included.
!certs/local/production.pem
```

With those files in the repo root, RepoPrompt copies ignored local files such as:

- `.env.local`
- `config/secrets.json`
- files under `certs/local/`

RepoPrompt does not copy:

- tracked files, even if their names match `.worktreeinclude`
- unignored untracked files
- files excluded by a later `!` pattern
- symlinks, directories, non-regular files, unsafe paths, or files that would overwrite an existing destination file

## Where it applies

`.worktreeinclude` copying only applies to RepoPrompt-managed worktrees, such as worktrees created under the app's `.repoprompt-worktrees` container by Agent Mode or `manage_worktree create`.

If you create a worktree at an explicit external path with `allow_external_path=true`, RepoPrompt creates the worktree but does not copy `.worktreeinclude` files into it.

## Output and diagnostics

Successful copying is silent. If everything requested is copied, RepoPrompt does not add extra output.

If something goes wrong after the worktree was created, RepoPrompt keeps the worktree and reports the copy issue where it can:

- `manage_worktree create` may include a warning in its output.
- Agent Mode and descriptor-only flows record production-safe diagnostics for debugging.

For example, if the destination file already exists, the worktree still exists and the warning explains that the file was skipped rather than overwritten.

## Be careful with broad patterns

RepoPrompt does not add a hidden file-count or size limit to `.worktreeinclude` copying. If you write a broad pattern such as `**` or `local-cache/**`, RepoPrompt may copy a lot of local data into every new app-managed worktree.

Use narrow patterns for the files agents actually need. A good `.worktreeinclude` is usually a short list of local setup files, not a second copy of your whole ignored cache directory.
