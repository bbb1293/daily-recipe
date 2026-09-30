# Project instructions

## Layout

- `generate-recipe.sh` — main script. Builds a prompt from the data files and recent history, calls Codex CLI (default) or Claude Code via `RECIPE_PROVIDER` / `--provider`, writes markdown + HTML output, and dispatches notifications (dialog, Discord). Codex defaults to `gpt-5.6-luna`; Claude uses its CLI's default model. `RECIPE_MODEL` / `--model` optionally overrides the model. Codex recipe runs reuse saved authentication but skip coding config and project instructions.
- `kitchen.sh` — manage the data files from the CLI: `kitchen list`, `kitchen add <list> <item>... [--urgent]`, `kitchen remove <list> <item>...`, `kitchen urgent <item>...`, `kitchen unurgent <item>...`. Matches items case-insensitively; mutations try exact first, then unique substring, and report multiple substring matches without changing files. Honors `KITCHEN_DATA_DIR` for testing. Shared by the Discord `/kitchen` command.
- `test/kitchen.test.sh` — dependency-free zsh tests for `kitchen.sh`. Run with `zsh test/kitchen.test.sh`.
- `test/generate-recipe.test.sh` — isolated zsh integration tests for both recipe providers using mocked CLIs. Run with `zsh test/generate-recipe.test.sh`; no model calls or notifications.
- `bot/natural-language.js` and `bot/natural-language.schema.json` — interpret Discord bot mentions with Codex CLI (GPT-5.6 Luna by default), validate the entire plan, and map actions to fixed recipe/kitchen command arguments. Shell tools are disabled for interpretation; model output is never evaluated as shell code.
- `bot/message-handler.js` — handle human bot mentions in the configured guild, optional user allowlisting, one request at a time, and complete Discord replies split into messages. `bot/index.js` connects this to `messageCreate`; existing slash commands remain available.
- `test/natural-language.test.js` and `test/message-handler.test.js` — dependency-free Node tests for interpretation, validation, execution, routing, concurrency, failures, and full-length replies. Run with `npm test --prefix bot`.
- `ingredients.txt` — current on-hand ingredients, one per line. `#` comments and blank lines are ignored. A trailing `!urgent` marks items close to expiring; they're surfaced separately in the prompt and every cook-now recipe must use at least one.
- `pantry.txt` — always-available staples. Same comment/blank rules. Items here are never tagged as MISSING.
- `recipes/` — generated output, one file per date: `YYYY-MM-DD.md` and `YYYY-MM-DD.html`. The last 3 files (by mtime) are fed back into the prompt to avoid repeats. Cached recipes are shared across providers; `--force` regenerates them, preserving the previous recipe on model failure.
- `recipe.css` — stylesheet copied into `recipes/` alongside the HTML so browsers can load it.
- `config.sh` — optional, gitignored local config sourced by the script (e.g. `DISCORD_WEBHOOK_URL`). See `config.sh.example`.
- `ingredients.example.txt`, `pantry.example.txt` — committed templates for the gitignored real files.
- `launchd/com.daily-recipe.plist.template` — template for the macOS launchd job that runs the script on a schedule.
- `generate-recipe.log` — append-only runtime log.
- `AGENTS.md` and `CLAUDE.md` — matching project instructions for Codex and Claude Code. Keep these standalone files in sync.

## Response style

Skip preamble and end-of-turn summaries. Answer directly.

## Feature suggestions

When the user proposes a feature, if you see a clearly better alternative (simpler, more reliable, or better fits the codebase), say so before implementing. Don't bikeshed minor stylistic choices — only speak up when the alternative is meaningfully better.

## Release workflow

After introducing a new feature, ask whether to:

1. Create a commit.
2. Push to `origin`.
3. Add an appropriate annotated semver tag (e.g. `v0.5.0`) and push it.

The project uses `vMAJOR.MINOR.PATCH` annotated tags with subject lines shaped like `vX.Y.Z — <short description>`. Run `git tag -l --format='%(refname:short) %(subject)' --sort=-creatordate | head` to see recent examples before picking the next version.
