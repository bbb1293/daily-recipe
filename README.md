# daily-recipe

A local macOS tool that generates **three on-hand recipes plus one recommended stretch recipe every night for the next day's meal**, based on what's currently in your kitchen.

It reads `ingredients.txt` (what you have) and `pantry.txt` (staples always available), calls the `claude` CLI to draft three recipes that use only those ingredients plus one "stretch" recipe that may add 1–2 items worth a quick shop, renders them to a styled HTML page, and pops a macOS dialog at 10:00 PM so you can pick one before bed.

---

## Features

- **Three on-hand options + one stretch recipe per day.** Part A gives three zero-friction recipes using only what's already in your kitchen; Part B recommends one slightly more ambitious dish that may call for 1–2 extra items worth a quick shop.
- **Uses what you actually have.** Reads a plain-text list of ingredients and pantry staples.
- **Freshness-aware.** Suffix any item with `!urgent` in `ingredients.txt` and every on-hand recipe is required to use at least one urgent item — good for ingredients close to expiration.
- **Shopping list is obvious.** In the stretch recipe, anything not already on hand is tagged `(MISSING — need to buy)` and highlighted in red in the rendered HTML. The three on-hand options never contain MISSING items.
- **Detailed recipes.** Exact grams / tbsp / tsp quantities and exact times & temperatures — no vague "a bit of".
- **Diverse rotation.** Feeds the last 3 days of recipes back into the prompt as "avoid repeating these" so you don't see kimchi stir-fry three days in a row.
- **Simple & healthy bias.** Short cooking time, balanced macros, no deep-fry-heavy suggestions.
- **Scheduled nightly.** A macOS `launchd` job runs the generator at 10:00 PM; a dialog pops with an **Open** button that launches the styled HTML in your default browser.
- **Runnable from the command line too.** A `recipe` command with flags for ad-hoc generation.
- **Optional Discord posting.** Pass `--notify discord` (wired into the launchd template by default) to post the day's recipes to a Discord webhook — handy for reading from your phone.

---

## Requirements

- macOS (uses `launchd` and `osascript` for scheduling and dialogs).
- [Claude Code CLI](https://claude.com/claude-code) (`claude` on PATH) — this powers recipe generation.
- [pandoc](https://pandoc.org/) — converts markdown to styled HTML.
- `zsh` (default on modern macOS).
- `jq` — only if you use `--notify discord` (used to JSON-encode the webhook payload). macOS ships with a system `jq` at `/usr/bin/jq`; if yours is missing, install with Homebrew.

Install the dependencies:

```sh
brew install pandoc
brew install jq   # only needed for --notify discord
# claude CLI: follow https://docs.claude.com/en/docs/claude-code
```

---

## Install

You can clone this repo **anywhere** — the script locates its own directory at runtime, so `~/personal/food`, `~/projects/daily-recipe`, or any other path works.

```sh
# 1. Clone wherever you like, then cd into it
git clone https://github.com/<your-username>/daily-recipe.git
cd daily-recipe

# 2. Seed your lists from the examples
cp ingredients.example.txt ingredients.txt
cp pantry.example.txt pantry.txt

# 3. Put the `recipe` command on your PATH
mkdir -p ~/.local/bin
ln -s "$PWD/generate-recipe.sh" ~/.local/bin/recipe

# (If ~/.local/bin isn't on your PATH yet, add this to your shell rc:)
# export PATH="$HOME/.local/bin:$PATH"

# 4. (Optional) Enable Discord notifications
#    Copy the template, then paste your webhook URL.
cp config.sh.example config.sh
# Open config.sh and set DISCORD_WEBHOOK_URL="https://discord.com/api/webhooks/..."
# Skip this step if you don't use Discord — the launchd job will simply log a
# "DISCORD_WEBHOOK_URL not set" line and carry on.

# 5. Install the nightly launchd job
#    This rewrites the template with your actual clone path, then loads it.
mkdir -p ~/Library/LaunchAgents
sed "s|__PROJECT_DIR__|$PWD|g" launchd/com.daily-recipe.plist.template \
  > ~/Library/LaunchAgents/com.user.daily-recipe.plist
launchctl load ~/Library/LaunchAgents/com.user.daily-recipe.plist
```

After step 5 the generator runs at **10:00 PM local time** each day, producing the next day's recipes.

---

## Usage

### Nightly (automatic)

At 10:00 PM `launchd` fires `generate-recipe.sh`, which:

1. Reads `ingredients.txt` and `pantry.txt`.
2. Prompts `claude` for three on-hand recipes plus one recommended stretch recipe for tomorrow.
3. Writes `recipes/YYYY-MM-DD.md` and a styled `recipes/YYYY-MM-DD.html`.
4. Pops a macOS dialog — click **Open** to view the rendered HTML in your browser, or **Later** to dismiss.

If your Mac is asleep at 10pm, `launchd` fires the job the next time it wakes.

### Command line

The same script is exposed as `recipe`:

```sh
recipe                           # Generate tomorrow's recipes (skip if already generated)
recipe --today                   # Generate for today
recipe --date 2026-05-01         # Generate for a specific date
recipe --force                   # Regenerate even if the target file exists
recipe --print                   # Force print to stdout (useful inside pipelines)
recipe --notify discord          # Also post the result to a Discord webhook
recipe --help
```

Behavior differs by how it's invoked:

- **Interactive terminal** (default): recipe markdown prints to stdout. The HTML is still written to `recipes/`.
- **Headless** (launchd, cron, pipes): a modal dialog pops with **Later** / **Open** buttons.

`--notify discord` posts every time the script runs, whether the recipe was freshly generated or already existed. If you re-run for the same date the channel will get another copy — useful for re-reading on your phone, noisy if you trigger the script repeatedly.

---

## File layout

```
.
├── generate-recipe.sh          # main script (also linked as `recipe`)
├── recipe.css                  # stylesheet used by the rendered HTML
├── ingredients.txt             # your current ingredients (gitignored)
├── ingredients.example.txt     # starter template (tracked)
├── pantry.txt                  # always-on-hand staples (gitignored)
├── pantry.example.txt          # starter template (tracked)
├── config.sh                   # local secrets, e.g. DISCORD_WEBHOOK_URL (gitignored)
├── config.sh.example           # starter template (tracked)
├── recipes/                    # generated .md + .html output (gitignored)
├── launchd/
│   └── com.daily-recipe.plist.template  # install template for the nightly job
├── generate-recipe.log         # per-run log (gitignored)
└── launchd.{out,err}.log       # launchd stdout/stderr (gitignored)
```

---

## Editing your lists

Both files are plain text, one item per line. Lines starting with `#` are ignored.

`ingredients.txt` — things sitting in your fridge/freezer/counter right now. This is what you're trying to "use up". Add tags like `(frozen)` if you want the recipe to know. Suffix any line with `!urgent` (e.g. `spinach !urgent`) for items close to expiration — every one of the three on-hand recipes will be required to use at least one urgent item.

`pantry.txt` — staples you *always* have. Items here are assumed available and **never** tagged as missing. Adjust to match your kitchen.

The three on-hand options never reach beyond your lists. The recommended stretch recipe may add up to two items, each tagged `(MISSING — need to buy)` — that's your (optional) shopping list for the day.

---

## Customizing

### Change the schedule

Edit `~/Library/LaunchAgents/com.user.daily-recipe.plist`, adjust the `<key>Hour</key>` / `<key>Minute</key>` values, then reload:

```sh
launchctl unload ~/Library/LaunchAgents/com.user.daily-recipe.plist
launchctl load   ~/Library/LaunchAgents/com.user.daily-recipe.plist
```

### Change the look of the rendered HTML

Edit `recipe.css`. The page uses system fonts and respects light/dark mode via `prefers-color-scheme`. The `(MISSING — need to buy)` tag is styled via the `.missing` class — tweak color or remove the pill styling there.

### Change what the LLM is asked for

The prompt lives inside `generate-recipe.sh` (search for `You are a home cook`). It's split into Part A (three on-hand recipes) and Part B (one recommended stretch recipe). Adjust the numbered criteria, part structure, output format, or history-window size (currently the last 3 days) directly.

### Disable Discord posting

The installed launchd plist includes `--notify discord` by default. To turn it off, edit `~/Library/LaunchAgents/com.user.daily-recipe.plist`, remove the two `<string>--notify</string>` / `<string>discord</string>` lines from `ProgramArguments`, then `launchctl unload` + `launchctl load` the plist to apply.

---

## Troubleshooting

- **Notification dialog never appeared at 10pm.** Check Focus / Do Not Disturb wasn't active. The modal dialog is AppleScript-driven and will queue to the next unlocked session if needed.
- **The "Open" button didn't launch the file.** Make sure `pandoc` is installed so an `.html` gets generated (the default app resolution for `.md` alone often fails).
- **"ingredients.txt is empty, skipping"** in the log. The file is either empty or contains only comments.
- **Script runs, but `claude` fails.** Check `generate-recipe.log` — most often this is an expired Claude Code auth session. Run `claude` interactively once to refresh.
- **Discord posts never arrive.** Look for `DISCORD_WEBHOOK_URL not set` in `generate-recipe.log` (fill in `config.sh`), or a curl error (bad/expired webhook URL).

---

## Uninstall

```sh
launchctl unload ~/Library/LaunchAgents/com.user.daily-recipe.plist
rm ~/Library/LaunchAgents/com.user.daily-recipe.plist
rm ~/.local/bin/recipe
# Then delete the clone directory wherever you put it
```
