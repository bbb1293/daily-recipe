# Discord Bot Listener — Design

## Summary

A long-running Node.js bot that exposes three Discord slash commands and shells out to the existing `generate-recipe.sh` CLI. Recipes arrive as messages in the channel where the slash command was invoked. The bot is guild-scoped, supervised by macOS `launchd` with `KeepAlive=true`, and shares config with the daily flow through `config.sh`.

This is **Phase 2**. Phase 1 (the `--use` CLI flag) shipped in `v0.7.0`.

## Motivation

After Phase 1, generating an ad-hoc recipe requires SSH or being at the Mac. The bot makes the same capability reachable from a phone via Discord, plus on-demand access to the nightly daily recipes without needing the Mac unlocked.

## Approach

Approach A from brainstorming: the bot is a thin Node layer that delegates all recipe logic to `generate-recipe.sh`. Zero duplication of prompt construction, MISSING-tagging, or `claude`-invocation.

## Slash commands

All three are registered guild-scoped to `DISCORD_GUILD_ID`. They do not appear in any other server the bot is in.

### `/cook ingredients:<string>`

Required string option. The bot splits on `,`, trims whitespace per item, and drops empty strings.

- If the parsed list is empty → reply `Please provide at least one ingredient.` and stop.
- Otherwise → spawn `./generate-recipe.sh --use a --use b ...` and post the captured stdout to the invocation channel.

### `/today`

No options.

- If `recipes/$(today).md` exists → read and post it.
- Otherwise → spawn `./generate-recipe.sh --today` and post the freshly-written `recipes/$(today).md`.

### `/tomorrow`

No options.

- If `recipes/$(tomorrow).md` exists → read and post it.
- Otherwise → spawn `./generate-recipe.sh` (no flags; default target is tomorrow) and post the freshly-written `recipes/$(tomorrow).md`.

No `regenerate` option on `/today` or `/tomorrow`. The bot never forces regeneration of an existing file. Force-regen remains a CLI-only capability (`recipe --today --force` on the Mac).

## Command flow

For every command:

1. **Defer** the interaction immediately (`interaction.deferReply()`). Discord requires an ack within 3 seconds; recipe generation takes ~20 seconds.
2. **Do the work** — read file or spawn `generate-recipe.sh`. The spawn inherits the project directory as cwd and the bot process's environment (which includes config sourced from `config.sh`).
3. **Post the result** via the chunking helper.

### Chunking helper

Discord's per-message limit is 2000 characters.

- If the markdown ≤ 2000 chars → post as one message via `editReply()`.
- Otherwise → split on `## ` (each H2 becomes one chunk; for the daily recipe this naturally yields one chunk per Option plus one for the Recommended stretch). `editReply()` the first chunk; `followUp()` each subsequent chunk.
- Each chunk is plain markdown — no embed splitting. Discord renders `**bold**`, lists, and headings natively in regular messages.

## File layout

```
bot/
  package.json            # discord.js + dotenv
  index.js                # gateway connection, command dispatch, chunking helper
  register-commands.js    # one-shot: registers the 3 slash commands to DISCORD_GUILD_ID
  .gitignore              # node_modules
launchd/
  com.daily-recipe.bot.plist.template   # new
config.sh.example         # +3 vars (DISCORD_BOT_TOKEN, DISCORD_APPLICATION_ID, DISCORD_GUILD_ID)
README.md                 # +section: bot setup
```

A single `bot/index.js` (~150 LOC) covers the three command handlers plus the chunking helper. The file does not need to be split today; if it grows past ~300 LOC during evolution, split per command (`bot/commands/cook.js`, etc.) at that point.

`generate-recipe.sh` is untouched. The existing webhook flow is untouched.

## Configuration

Three new variables added to `config.sh.example` (real values in the gitignored `config.sh`):

```sh
# Discord bot — needed only for bot/index.js.
# Create the bot in https://discord.com/developers/applications, then:
#   - Bot tab: Reset Token, paste below
#   - General Information tab: copy the Application ID
#   - In Discord (with Developer Mode on): right-click your server icon → Copy Server ID
# DISCORD_BOT_TOKEN="..."
# DISCORD_APPLICATION_ID="..."
# DISCORD_GUILD_ID="..."
```

The bot loads these via `dotenv` pointing at `config.sh` — its `KEY="value"` lines are dotenv-compatible. `DISCORD_WEBHOOK_URL` (Phase 1) is unaffected.

## Supervision

New launchd plist `launchd/com.daily-recipe.bot.plist.template`:

```xml
<key>Label</key>            <string>com.user.daily-recipe.bot</string>
<key>ProgramArguments</key> <array>
  <string>/opt/homebrew/bin/node</string>
  <string>__PROJECT_DIR__/bot/index.js</string>
</array>
<key>WorkingDirectory</key> <string>__PROJECT_DIR__</string>
<key>RunAtLoad</key>        <true/>
<key>KeepAlive</key>        <true/>
<key>StandardOutPath</key>  <string>__PROJECT_DIR__/bot.out.log</string>
<key>StandardErrorPath</key><string>__PROJECT_DIR__/bot.err.log</string>
```

Install pattern mirrors the existing daily plist: `sed` the placeholder, `launchctl load`. `KeepAlive=true` restarts the process on crash. Logs land in `bot.{out,err}.log` — separate from the daily job's `launchd.{out,err}.log` so the two streams stay legible.

If the user's Node lives somewhere other than `/opt/homebrew/bin/node`, the install instructions in the README tell them to adjust before loading.

## Slash command registration

`bot/register-commands.js` is a one-shot script. It calls Discord's REST `PUT /applications/{app_id}/guilds/{guild_id}/commands` with the full command set, which overwrites the previous registration. Guild-scoped registration is instant (global takes up to one hour).

Usage:

```sh
node bot/register-commands.js
```

Run it after first install, and whenever command definitions change. The bot runtime does NOT register on startup — that would hit the API on every launchd restart and risk rate limits.

## Error handling

| Condition | Behavior |
|---|---|
| Bot starts with any of `DISCORD_BOT_TOKEN` / `DISCORD_APPLICATION_ID` / `DISCORD_GUILD_ID` missing or empty | Log `missing required config: <var>` to stderr and exit 1. launchd will keep relaunching — fix the config to stop the loop. |
| Gateway disconnect | discord.js's built-in auto-reconnect. No special handling. |
| `/cook` with empty parsed ingredients list | `editReply("Please provide at least one ingredient.")` — no `claude` spawn. |
| `/today` or `/tomorrow` when target file is missing | Fall through to generation. |
| `generate-recipe.sh` exits non-zero | `editReply("Recipe generation failed. Check generate-recipe.log on the host.")` and log the failing command + exit code + a tail of stderr to `bot.err.log`. |
| `generate-recipe.sh` exceeds its internal 10-min timeout | Same — exits non-zero, same error path. |
| Bot crash mid-interaction | launchd respawns. The pending Discord interaction expires (~15 min); the user sees Discord's standard "application did not respond". They can re-invoke. |
| Slash command received that the bot doesn't recognize | Log a warning and reply with `Unknown command — try re-running register-commands.js.` |
| Bot ends up in a guild other than `DISCORD_GUILD_ID` | Commands aren't registered there. No-op. |

## Security

Single layer: slash commands are registered only to `DISCORD_GUILD_ID`. Anyone with access to that guild can invoke them. No per-user or per-channel allowlist inside the bot.

Channel-level restriction, if desired, is configured through Discord's built-in UI (Server Settings → Integrations → bot → Channels), not in the bot code.

## Manual test plan

- **Foreground smoke run.** `node bot/index.js` in a terminal. Observe `Logged in as ...` line. Run from Discord:
  - `/cook ingredients: chicken` → recipe arrives in the channel as one or more messages.
  - `/cook ingredients: chicken, spinach` → both ingredients appear in the recipe.
  - `/cook ingredients:` (whitespace only) → `Please provide at least one ingredient.`
  - `/today` when `recipes/<today>.md` exists → existing content arrives.
  - `/today` after `rm recipes/<today>.md` → generation runs, fresh content arrives.
  - `/tomorrow` analogous.
- **Failure path.** Temporarily move `ingredients.txt` away, run `/today` with no cached file → bot responds with the failure message, `bot.err.log` records the exit code.
- **Supervision.** `launchctl load` the bot plist. Find the PID with `launchctl list | grep daily-recipe.bot`. Kill it with `kill <pid>`. Confirm `launchctl list | grep daily-recipe.bot` shows a new PID within a few seconds.

## Out of scope

- Force-regenerate from Discord (the user kept this CLI-only).
- Per-channel allowlist inside the bot (use Discord's built-in Integration UI).
- Per-user allowlist (guild-scope is the only gate).
- Cross-guild support, sharding, or any global slash command path.
- Multi-bot or HA — single Mac, single process.
- Reading the recipe HTML or rendering anything other than the markdown source.
