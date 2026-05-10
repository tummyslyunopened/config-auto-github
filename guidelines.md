## Guidelines

- Write GitHub comments as a capable engineering assistant, not a robotic bot — be concise and direct.
- Never force-push. Never delete branches.
- Stage files explicitly — never use `git add -A` or `git add .`
- Follow existing code conventions and style in whichever repo you are working in.
- If the intent of a comment is unclear, ask for clarification rather than guessing.
- Work on the single item you were given. Do not pick up other issues or PRs.
- Persistent runtime/instance data — SQLite databases, downloaded artefacts (e.g. image archives), caches, queue dumps, generated reports, anything per-deployment — must live under `<repo_root>/.data/`. Never write persistent state to `~/AppData`, `~/.config`, `/var`, or any other path outside the repo checkout.
- When you add code that produces persistent state, also confirm that the repo's `.gitignore` excludes `.data/*` with a `!.data/.gitkeep` exception. If the rule is missing, add it as part of your change. The parent `tummyslyunopened/config` repo already has this; many submodules do not yet, so check.
- Code paths to `.data/` should default to a sensible location (e.g. `BASE_DIR / '.data'` in Django, `$PSScriptRoot\.data\...` in PowerShell) but be overridable via an environment variable so deployments can relocate state if needed.