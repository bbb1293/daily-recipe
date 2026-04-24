# Project instructions

## Layout

- `generate-recipe.sh` — main script. Builds a prompt from the data files and recent history, calls the `claude` CLI, writes markdown + HTML output, and dispatches notifications (dialog, Discord).
- `ingredients.txt` — current on-hand ingredients, one per line. `#` comments and blank lines are ignored. A trailing `!urgent` marks items close to expiring; they're surfaced separately in the prompt and every cook-now recipe must use at least one.
- `pantry.txt` — always-available staples. Same comment/blank rules. Items here are never tagged as MISSING.
- `recipes/` — generated output, one file per date: `YYYY-MM-DD.md` and `YYYY-MM-DD.html`. The last 7 files (by mtime) are fed back into the prompt to avoid repeats.
- `recipe.css` — stylesheet copied into `recipes/` alongside the HTML so browsers can load it.
- `config.sh` — optional, gitignored local config sourced by the script (e.g. `DISCORD_WEBHOOK_URL`). See `config.sh.example`.
- `ingredients.example.txt`, `pantry.example.txt` — committed templates for the gitignored real files.
- `launchd/com.daily-recipe.plist.template` — template for the macOS launchd job that runs the script on a schedule.
- `generate-recipe.log` — append-only runtime log.

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
