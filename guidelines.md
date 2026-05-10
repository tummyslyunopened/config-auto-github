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
- Some submodules use the user's SSH alias `github:owner/repo` form for git remotes (defined in their `~/.ssh/config` Host github stanza, which uses the `~/.ssh/github-primary` identity). This is intentional config — do not rewrite SSH alias URLs to plain `git@github.com:...` or HTTPS to "fix" a push failure. If a push fails with "Permission denied (publickey)", the remote URL is fine; the issue is that the calling shell does not have access to the SSH key. Investigate the key/agent state instead.
- When adding a new submodule or git remote, prefer the `github:owner/repo` form to match the existing convention.
- Before opening a PR, do a documentation pass on the affected repo:
  - **README.md**: update if the change touches user-facing setup, run instructions, env vars, or any documented behaviour. If the repo has no README and your change introduces public behaviour, add one. Mirror the structure of similar repos (one-paragraph description, Stack, Setup, Configuration).
  - **SPEC.md** (present in some repos like `config-itam`, `config-itsm`) is a **read-mostly source of truth** and its own header forbids adding to it without authorisation. Do not add new spec items. If your change implements something the spec already covers, you may tighten the wording. If you find spec/code drift, raise it in the PR description rather than silently editing the spec.
  - **Parent docs site** at `tummyslyunopened/config/docs/` (mkdocs Material). Update only the pages your change actually affects:
    - `docs/reference/submodules.md` when changing what a submodule does, its role, or how it is invoked.
    - `docs/getting-started.md` when changing setup or onboarding steps.
    - `docs/workflow.md` when changing the deploy/sync workflow.
    - Leave unrelated pages alone.
- Documentation updates ship in the **same PR** as the code change, not a follow-up. Reviewers see code and docs together.
## Designer Q&A via Telegram

- For low-stakes clarifying questions that aren't worth a full GitHub issue/comment, you may ask the designer directly via Telegram. Run, from a Bash tool, `pwsh.exe -NoProfile -File ./config-auto-github/telegram-ask.ps1 -Question "..." -TimeoutSec 300` (path is relative to repo root). It blocks up to 5 minutes waiting for a quoted-reply.
- **Exit codes**: `0` = reply received (text printed on stdout, use it). `124` = timeout. `2/3/4` = configuration / network failure.
- **On timeout (124)**: do NOT block further. Post a clarifying comment on the GitHub issue using `gh issue comment`, then end the session cleanly. The worker will pick up the issue again when the designer replies in GitHub (the monitor catches new comments on the next pass).
- **Use sparingly**: questions interrupt the designer's day. Prefer concrete proposals to open-ended asks. Good: "I'm about to bump python to 3.13 in this submodule -- ok?" Bad: "what should I do here?"
- `telegram-ask.ps1` is the **only** path through which designer-typed text can reach you. The script enforces a security filter (replies must be quoted-replies to your own outgoing message in the right chat) -- you cannot bypass it. Don't try to read `.data/telegram/` files directly; the inbox dump is unfiltered audit data.
