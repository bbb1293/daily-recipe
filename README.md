# daily-recipe

Generates **three on-hand recipes plus one stretch recipe** each night for the next day, based on what's in your kitchen. It reads `ingredients.txt` and `pantry.txt`, asks the `claude` CLI for recipes that use only those items (plus a stretch dish that may need 1–2 extras), renders styled HTML, and pops a macOS dialog at 10 PM.

---

## Features

- **3 on-hand + 1 stretch per day.** Part A: three recipes from what you have. Part B: one more ambitious dish that may need 1–2 extra items.
- **Freshness-aware.** Suffix an item with `!urgent` and every on-hand recipe must use at least one urgent item.
- **Clear shopping list.** Extras in the stretch recipe are tagged `(MISSING — need to buy)` and shown in red; on-hand recipes never contain them.
- **Precise.** Exact quantities, times, and temperatures — no vague "a bit of".
- **Varied.** The last 3 days of recipes are fed back as "avoid repeating".
- **Scheduled.** A `launchd` job runs nightly and opens the HTML in your browser.
- **CLI + Discord.** A `recipe` command for ad-hoc runs; optional webhook posting and a slash-command bot.

---

## Requirements

macOS, plus:

- [Claude Code CLI](https://claude.com/claude-code) (`claude` on PATH) — generates the recipes.
- [pandoc](https://pandoc.org/) — markdown → styled HTML.
- `zsh` (default on macOS).
- `jq` — only for `--notify discord`.

```sh
brew install pandoc
brew install jq   # only for --notify discord
```

---

## Install

Clone anywhere — the script locates its own directory at runtime.

```sh
git clone https://github.com/<your-username>/daily-recipe.git
cd daily-recipe

# Seed your lists from the examples
cp ingredients.example.txt ingredients.txt
cp pantry.example.txt pantry.txt

# Put `recipe` on your PATH (add ~/.local/bin to PATH if it isn't already)
mkdir -p ~/.local/bin
ln -s "$PWD/generate-recipe.sh" ~/.local/bin/recipe

# Optional: Discord notifications — copy the template, then set DISCORD_WEBHOOK_URL
cp config.sh.example config.sh

# Install the nightly job (rewrites the template with your path, then loads it)
mkdir -p ~/Library/LaunchAgents
sed "s|__PROJECT_DIR__|$PWD|g" launchd/com.daily-recipe.plist.template \
  > ~/Library/LaunchAgents/com.user.daily-recipe.plist
launchctl load ~/Library/LaunchAgents/com.user.daily-recipe.plist
```

The generator now runs at **10 PM local time** for the next day's meal. If the Mac is asleep, it runs at the next wake.

---

## Usage

Once installed, the nightly job writes `recipes/YYYY-MM-DD.{md,html}` and pops a dialog — click **Open** to view the HTML, **Later** to dismiss. You can also run it by hand via the `recipe` command:

```sh
recipe                           # tomorrow's recipes (skip if already generated)
recipe --today                   # today
recipe --date 2026-05-01         # a specific date
recipe --force                   # regenerate even if the file exists
recipe --print                   # force print to stdout
recipe --notify discord          # also post to a Discord webhook
recipe --use chicken             # one recipe centered on an ingredient
recipe --use chicken --use rice  # repeatable; all named items must appear
recipe --help
```

- **Interactive terminal:** markdown prints to stdout (HTML still written to `recipes/`).
- **Headless** (launchd/cron/pipes): a dialog pops with **Later** / **Open**.
- `--notify discord` posts on every run, even if the recipe already existed.

`--use` builds a single recipe that includes every named ingredient, drawing the rest from your lists; named items not on either list are tagged `(MISSING — need to buy)`. It prints to stdout (and Discord), isn't saved to `recipes/`, and can't combine with `--date`/`--today`/`--force`.

---

## File layout

Gitignored paths each ship a tracked `.example` (or `.template`) starter.

```
.
├── generate-recipe.sh   # nightly recipe generator (installed as `recipe`)
├── kitchen.sh           # manage your ingredient/pantry lists from the CLI
├── recipe.css           # stylesheet for the rendered HTML
├── ingredients.txt      # current ingredients         (gitignored)
├── pantry.txt           # always-on-hand staples       (gitignored)
├── config.sh            # local secrets, e.g. DISCORD_WEBHOOK_URL (gitignored)
├── recipes/             # generated .md + .html output (gitignored)
├── bot/                 # Discord bot (index.js, register-commands.js)
├── test/                # zsh tests (kitchen.test.sh)
├── launchd/             # .plist templates for the nightly job + the bot
└── *.log                # per-run and launchd logs     (gitignored)
```

---

## Your lists

Plain text, one item per line; `#` lines are ignored.

- **`ingredients.txt`** — what you have right now. Tag an item `!urgent` (e.g. `spinach !urgent`) for things near expiry; every on-hand recipe must then use at least one. Free-form notes like `(frozen)` are fine.
- **`pantry.txt`** — staples you always have; never tagged missing.

Only the stretch recipe reaches beyond your lists, adding up to two `(MISSING — need to buy)` items — your optional shopping list.

Edit the files by hand, or use `kitchen.sh` (or the Discord `/kitchen` command):

```sh
./kitchen.sh list [ingredients|pantry]            # show lists (urgent flagged)
./kitchen.sh add ingredients "chicken thighs" --urgent
./kitchen.sh add pantry "fish sauce"
./kitchen.sh remove ingredients "spinach"
./kitchen.sh urgent "spinach"                      # or: unurgent
```

Items match case-insensitively. `remove`/`urgent`/`unurgent` try an exact match, then a unique substring; an ambiguous substring changes nothing and lists the candidates. `--urgent` applies only to ingredients.

Discord mirrors these as `/kitchen list|add|remove|urgent|unurgent` (the `items` field is comma-separated). Re-run `node bot/register-commands.js` after changing command definitions.

---

## Customizing

- **Schedule** — edit `Hour`/`Minute` in `~/Library/LaunchAgents/com.user.daily-recipe.plist`, then `launchctl unload && launchctl load` it.
- **HTML look** — edit `recipe.css` (system fonts; light/dark via `prefers-color-scheme`; the `.missing` class styles the buy tag).
- **The prompt** — in `generate-recipe.sh` (search `You are a home cook`): Part A (on-hand) / Part B (stretch), criteria, output format, history window (3 days).
- **Language** — set `RECIPE_LANGUAGE` in `config.sh` (e.g. `"Korean"`, `"日本語"`). The recipe body is translated; UI strings and the `(MISSING — need to buy)` tag stay English so the HTML highlighter keeps working. Empty = English. Sourced each run, no restart.
- **Disable Discord posting** — remove the `--notify` / `discord` lines from `ProgramArguments` in the plist, then reload it.

---

## Discord bot (optional)

Run the bot in `bot/` to drive the tool from Discord. Guild-scoped slash commands:

- `/cook ingredients: chicken, spinach` — one ad-hoc recipe (the `--use` flow).
- `/today`, `/tomorrow` — the daily recipe (cached if present, else generated).
- `/kitchen ...` — manage your lists (see [Your lists](#your-lists)).

### Setup

1. Create an app at https://discord.com/developers/applications. Copy the **bot token** (Bot → Reset Token) and the **Application ID**; with Developer Mode on, copy your **Server ID**; in OAuth2 → URL Generator, check `bot` + `applications.commands`, then open the URL to invite the bot.
2. Add the IDs to `config.sh`:
   ```sh
   DISCORD_BOT_TOKEN="..."
   DISCORD_APPLICATION_ID="..."
   DISCORD_GUILD_ID="..."
   ```
3. Install deps and register commands (idempotent — re-run when commands change):
   ```sh
   cd bot && npm install && node register-commands.js
   ```
4. Install the supervisor job:
   ```sh
   sed "s|__PROJECT_DIR__|$PWD/..|g" ../launchd/com.daily-recipe.bot.plist.template \
     > ~/Library/LaunchAgents/com.user.daily-recipe.bot.plist
   launchctl load ~/Library/LaunchAgents/com.user.daily-recipe.bot.plist
   ```
   Logs go to `bot.out.log` / `bot.err.log`; `KeepAlive=true` restarts on crash. If `node` isn't at `/opt/homebrew/bin/node`, edit the template first.

Uninstall the bot: `launchctl unload` then `rm` `~/Library/LaunchAgents/com.user.daily-recipe.bot.plist`.

---

## Troubleshooting

- **No dialog at 10 PM** — check Focus / Do Not Disturb; the dialog queues to the next unlocked session.
- **"Open" did nothing** — install `pandoc` so an `.html` is generated (opening `.md` alone often fails).
- **"ingredients.txt is empty, skipping"** — the file is empty or all comments.
- **`claude` fails** — usually an expired auth session; run `claude` once interactively. See `generate-recipe.log`.
- **No Discord posts** — look for `DISCORD_WEBHOOK_URL not set` in the log, or a bad/expired webhook URL.

---

## Uninstall

```sh
launchctl unload ~/Library/LaunchAgents/com.user.daily-recipe.plist
rm ~/Library/LaunchAgents/com.user.daily-recipe.plist
rm ~/.local/bin/recipe
# then delete the clone directory
```
