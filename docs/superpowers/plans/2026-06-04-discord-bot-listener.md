# Discord Bot Listener Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a Node.js Discord bot that exposes three slash commands (`/cook`, `/today`, `/tomorrow`) by shelling out to the existing `generate-recipe.sh` CLI. Recipes are posted in the channel where the command was invoked.

**Architecture:** Approach A from the spec — a thin bot that delegates all recipe logic to the CLI. Single-process bot supervised by macOS launchd (KeepAlive=true). Guild-scoped slash commands registered via a one-shot script. Bot reads `config.sh` via `dotenv` for the three new Discord variables.

**Tech Stack:** Node.js 18+ (project uses 25.9.0), `discord.js@^14.16`, `dotenv@^16.4`. No test framework — verification is manual at each task, mirroring Phase 1.

**Spec:** `docs/superpowers/specs/2026-06-04-discord-bot-listener-design.md`

**Prerequisite — user must create a Discord app before this can be tested end-to-end:** go to https://discord.com/developers/applications, "New Application", add a Bot, copy the Bot Token + Application ID, and invite the bot to one server. We surface that step in the README (Task 5), but implementation Tasks 1–4 can land without it. Task 6 (acceptance) requires it.

---

## File Structure

New files:
- `/Users/mac/personal/food/bot/package.json` — Node manifest (dependencies, scripts)
- `/Users/mac/personal/food/bot/.gitignore` — `node_modules/`
- `/Users/mac/personal/food/bot/register-commands.js` — one-shot slash-command registration
- `/Users/mac/personal/food/bot/index.js` — bot runtime (connect, dispatch, three handlers, chunking helper)
- `/Users/mac/personal/food/launchd/com.daily-recipe.bot.plist.template` — supervision

Modified files:
- `/Users/mac/personal/food/config.sh.example` — append three Discord bot variables
- `/Users/mac/personal/food/README.md` — append a "Discord bot" section

Untouched:
- `generate-recipe.sh`, `recipe.css`, all existing launchd files, all existing recipe data.

The whole bot fits in a single ~120-LOC `index.js`. We do not split per command today — the spec calls out the threshold where splitting becomes worth doing (file > 300 LOC), and we are well under that.

---

## Task 1: Scaffolding — package.json, .gitignore, config.sh.example

**Files:**
- Create: `/Users/mac/personal/food/bot/package.json`
- Create: `/Users/mac/personal/food/bot/.gitignore`
- Modify: `/Users/mac/personal/food/config.sh.example` (append three lines)

**Why:** Land the static scaffolding first. After this task, `npm install` works inside `bot/`, and the example config documents the new Discord variables. No runtime behavior changes.

- [ ] **Step 1: Create `bot/package.json`**

Write exactly:

```json
{
  "name": "daily-recipe-bot",
  "version": "1.0.0",
  "private": true,
  "description": "Discord bot listener for the daily-recipe project (Phase 2).",
  "main": "index.js",
  "scripts": {
    "start": "node index.js",
    "register": "node register-commands.js"
  },
  "dependencies": {
    "discord.js": "^14.16.0",
    "dotenv": "^16.4.0"
  }
}
```

- [ ] **Step 2: Create `bot/.gitignore`**

Write exactly:

```
node_modules/
package-lock.json
```

(`package-lock.json` is intentionally ignored because the bot is single-machine and we don't need reproducible installs across environments. If the user later wants deterministic builds, remove that line.)

- [ ] **Step 3: Install dependencies**

Run:

```bash
cd /Users/mac/personal/food/bot && npm install
```

Expected: a `node_modules/` directory and a `package-lock.json` appear (the lock file is gitignored so it won't be staged). No errors. `npm install` should produce output like `added N packages in Xs`.

If `npm install` complains about a missing Node version, abort with NEEDS_CONTEXT — the project assumes Node 18+ per the spec.

- [ ] **Step 4: Update `config.sh.example`**

Read `/Users/mac/personal/food/config.sh.example`. Append the following block to the end (preserve the existing webhook lines):

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

- [ ] **Step 5: Verify staging shape**

Run:

```bash
cd /Users/mac/personal/food
git status
```

Expected:
- New files: `bot/.gitignore`, `bot/package.json`
- Modified: `config.sh.example`
- NOT shown: `bot/node_modules/`, `bot/package-lock.json` (these should be ignored by `bot/.gitignore`)

If `bot/node_modules/` or `bot/package-lock.json` appear in `git status`, the `.gitignore` isn't taking effect — fix it before committing.

- [ ] **Step 6: Commit**

```bash
cd /Users/mac/personal/food
git add bot/package.json bot/.gitignore config.sh.example
git commit -m "Scaffold bot/ directory and document Discord bot config"
```

---

## Task 2: Slash-command registration script

**Files:**
- Create: `/Users/mac/personal/food/bot/register-commands.js`

**Why:** The bot's runtime in Task 3 won't register commands on startup (we want manual, idempotent registration). This script is the one-shot the user runs after install or whenever command definitions change.

- [ ] **Step 1: Create `bot/register-commands.js`**

Write exactly:

```js
const path = require('node:path');
require('dotenv').config({ path: path.join(__dirname, '..', 'config.sh') });

const { REST, Routes } = require('discord.js');

const REQUIRED = ['DISCORD_BOT_TOKEN', 'DISCORD_APPLICATION_ID', 'DISCORD_GUILD_ID'];
for (const key of REQUIRED) {
  if (!process.env[key]) {
    console.error(`missing required config: ${key}`);
    process.exit(1);
  }
}

const commands = [
  {
    name: 'cook',
    description: 'Generate a recipe centered on specific ingredients',
    options: [
      {
        name: 'ingredients',
        description: 'Comma-separated list, e.g. "chicken, spinach"',
        type: 3, // STRING
        required: true,
      },
    ],
  },
  {
    name: 'today',
    description: "Fetch today's daily recipe (generate if missing)",
  },
  {
    name: 'tomorrow',
    description: "Fetch tomorrow's daily recipe (generate if missing)",
  },
];

const rest = new REST({ version: '10' }).setToken(process.env.DISCORD_BOT_TOKEN);

(async () => {
  try {
    await rest.put(
      Routes.applicationGuildCommands(
        process.env.DISCORD_APPLICATION_ID,
        process.env.DISCORD_GUILD_ID,
      ),
      { body: commands },
    );
    console.log(
      `Registered ${commands.length} commands to guild ${process.env.DISCORD_GUILD_ID}`,
    );
  } catch (err) {
    console.error('registration failed:', err);
    process.exit(1);
  }
})();
```

- [ ] **Step 2: Syntax check**

Run:

```bash
cd /Users/mac/personal/food/bot && node --check register-commands.js
```

Expected: no output, exit 0.

- [ ] **Step 3: Smoke test the missing-config error path**

Run without any of the required vars set:

```bash
cd /Users/mac/personal/food/bot
DISCORD_BOT_TOKEN= DISCORD_APPLICATION_ID= DISCORD_GUILD_ID= node register-commands.js
echo "exit: $?"
```

Expected: stderr line `missing required config: DISCORD_BOT_TOKEN`, exit code 1.

Note: this only validates the early-exit branch. The actual API call requires real credentials, which the user supplies in Task 6.

- [ ] **Step 4: Commit**

```bash
cd /Users/mac/personal/food
git add bot/register-commands.js
git commit -m "Add slash-command registration script"
```

---

## Task 3: Bot runtime — connect, dispatch, three handlers, chunking helper

**Files:**
- Create: `/Users/mac/personal/food/bot/index.js`

**Why:** This is the bot itself. It connects to Discord, listens for `interactionCreate`, dispatches the three slash commands, shells out to `generate-recipe.sh`, and posts results back via `editReply` / `followUp` with markdown chunking when needed.

- [ ] **Step 1: Create `bot/index.js`**

Write exactly:

```js
const path = require('node:path');
require('dotenv').config({ path: path.join(__dirname, '..', 'config.sh') });

const { spawn } = require('node:child_process');
const fs = require('node:fs/promises');

const { Client, GatewayIntentBits } = require('discord.js');

const REQUIRED = ['DISCORD_BOT_TOKEN', 'DISCORD_APPLICATION_ID', 'DISCORD_GUILD_ID'];
for (const key of REQUIRED) {
  if (!process.env[key]) {
    console.error(`missing required config: ${key}`);
    process.exit(1);
  }
}

const PROJECT_DIR = path.resolve(__dirname, '..');
const RECIPES_DIR = path.join(PROJECT_DIR, 'recipes');
const SCRIPT = path.join(PROJECT_DIR, 'generate-recipe.sh');
const DISCORD_MSG_LIMIT = 2000;

function dateStr(offsetDays = 0) {
  const d = new Date();
  d.setDate(d.getDate() + offsetDays);
  return d.toISOString().slice(0, 10); // YYYY-MM-DD
}

function runScript(args) {
  return new Promise((resolve, reject) => {
    let stdout = '';
    let stderr = '';
    const child = spawn(SCRIPT, args, { cwd: PROJECT_DIR });
    child.stdout.on('data', (chunk) => {
      stdout += chunk.toString();
    });
    child.stderr.on('data', (chunk) => {
      stderr += chunk.toString();
    });
    child.on('close', (code) => {
      if (code === 0) resolve(stdout);
      else reject(new Error(`generate-recipe.sh exited ${code}\nstderr: ${stderr.slice(-2000)}`));
    });
    child.on('error', reject);
  });
}

async function postMarkdown(interaction, markdown) {
  if (markdown.length <= DISCORD_MSG_LIMIT) {
    await interaction.editReply(markdown.length ? markdown : '(empty recipe)');
    return;
  }
  // Split on `\n## ` so each H2 becomes a chunk. Keep the `## ` prefix on chunks after the first.
  const parts = [];
  const split = markdown.split(/\n(?=## )/);
  for (const part of split) parts.push(part);

  let first = true;
  for (const part of parts) {
    let text = part;
    if (text.length > DISCORD_MSG_LIMIT) {
      text = text.slice(0, DISCORD_MSG_LIMIT - 1) + '…';
    }
    if (first) {
      await interaction.editReply(text);
      first = false;
    } else {
      await interaction.followUp(text);
    }
  }
}

async function reportFailure(interaction, err) {
  console.error('handler failure:', err);
  try {
    await interaction.editReply(
      'Recipe generation failed. Check `generate-recipe.log` and `bot.err.log` on the host.',
    );
  } catch (replyErr) {
    console.error('failed to edit reply after handler error:', replyErr);
  }
}

async function handleCook(interaction) {
  const raw = interaction.options.getString('ingredients', true);
  const items = raw
    .split(',')
    .map((s) => s.trim())
    .filter(Boolean);
  if (items.length === 0) {
    await interaction.editReply('Please provide at least one ingredient.');
    return;
  }
  const args = [];
  for (const item of items) {
    args.push('--use', item);
  }
  try {
    const stdout = await runScript(args);
    await postMarkdown(interaction, stdout);
  } catch (err) {
    await reportFailure(interaction, err);
  }
}

async function handleDaily(interaction, offsetDays) {
  const target = dateStr(offsetDays);
  const file = path.join(RECIPES_DIR, `${target}.md`);
  let markdown;
  try {
    markdown = await fs.readFile(file, 'utf8');
  } catch {
    // File missing — generate, then read again.
    try {
      const args = offsetDays === 0 ? ['--today'] : [];
      await runScript(args);
      markdown = await fs.readFile(file, 'utf8');
    } catch (err) {
      await reportFailure(interaction, err);
      return;
    }
  }
  await postMarkdown(interaction, markdown);
}

const client = new Client({ intents: [GatewayIntentBits.Guilds] });

client.once('ready', () => {
  console.log(`Logged in as ${client.user.tag}`);
});

client.on('interactionCreate', async (interaction) => {
  if (!interaction.isChatInputCommand()) return;
  await interaction.deferReply();
  try {
    switch (interaction.commandName) {
      case 'cook':
        await handleCook(interaction);
        break;
      case 'today':
        await handleDaily(interaction, 0);
        break;
      case 'tomorrow':
        await handleDaily(interaction, 1);
        break;
      default:
        console.warn('unknown command:', interaction.commandName);
        await interaction.editReply(
          'Unknown command — try re-running `node bot/register-commands.js`.',
        );
    }
  } catch (err) {
    await reportFailure(interaction, err);
  }
});

client.login(process.env.DISCORD_BOT_TOKEN);
```

- [ ] **Step 2: Syntax check**

Run:

```bash
cd /Users/mac/personal/food/bot && node --check index.js
```

Expected: no output, exit 0.

- [ ] **Step 3: Smoke test the missing-config error path**

```bash
cd /Users/mac/personal/food/bot
DISCORD_BOT_TOKEN= DISCORD_APPLICATION_ID= DISCORD_GUILD_ID= node index.js
echo "exit: $?"
```

Expected: stderr `missing required config: DISCORD_BOT_TOKEN`, exit 1.

Then test partial config:

```bash
cd /Users/mac/personal/food/bot
DISCORD_BOT_TOKEN=test_token DISCORD_APPLICATION_ID= DISCORD_GUILD_ID= node index.js
echo "exit: $?"
```

Expected: stderr `missing required config: DISCORD_APPLICATION_ID`, exit 1.

(End-to-end Discord login can't be tested without real credentials. Task 6 does that.)

- [ ] **Step 4: Commit**

```bash
cd /Users/mac/personal/food
git add bot/index.js
git commit -m "Implement Discord bot runtime with /cook, /today, /tomorrow"
```

---

## Task 4: launchd plist template

**Files:**
- Create: `/Users/mac/personal/food/launchd/com.daily-recipe.bot.plist.template`

**Why:** Keeps the bot alive across crashes and reboots, mirroring the existing daily-recipe job's supervision pattern.

- [ ] **Step 1: Detect the user's node path**

Run:

```bash
which node
```

Expected: an absolute path, almost certainly `/opt/homebrew/bin/node` on Apple Silicon Homebrew. If it's something else (e.g. `/usr/local/bin/node` for Intel Homebrew, or an `nvm` path), note it and use that value below.

- [ ] **Step 2: Create the plist template**

Write exactly:

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>com.user.daily-recipe.bot</string>

    <!-- Long-running Discord bot. Install instructions in README.
         Requires DISCORD_BOT_TOKEN / DISCORD_APPLICATION_ID / DISCORD_GUILD_ID
         in config.sh (loaded by bot/index.js via dotenv). -->
    <key>ProgramArguments</key>
    <array>
        <string>/opt/homebrew/bin/node</string>
        <string>__PROJECT_DIR__/bot/index.js</string>
    </array>

    <key>WorkingDirectory</key>
    <string>__PROJECT_DIR__</string>

    <key>RunAtLoad</key>
    <true/>

    <key>KeepAlive</key>
    <true/>

    <key>StandardOutPath</key>
    <string>__PROJECT_DIR__/bot.out.log</string>

    <key>StandardErrorPath</key>
    <string>__PROJECT_DIR__/bot.err.log</string>
</dict>
</plist>
```

If `which node` from Step 1 gave a path other than `/opt/homebrew/bin/node`, replace `/opt/homebrew/bin/node` in the file with that path. (The user will customize this again at install time anyway, but the template should reflect a sensible default for this machine.)

- [ ] **Step 3: Validate plist syntax**

Run:

```bash
plutil -lint /Users/mac/personal/food/launchd/com.daily-recipe.bot.plist.template
```

Expected: `... OK`.

The `__PROJECT_DIR__` placeholder is not a problem for `plutil` — it's a valid plist string.

- [ ] **Step 4: Commit**

```bash
cd /Users/mac/personal/food
git add launchd/com.daily-recipe.bot.plist.template
git commit -m "Add launchd plist template for the Discord bot"
```

---

## Task 5: README — document bot install

**Files:**
- Modify: `/Users/mac/personal/food/README.md`

**Why:** The bot has its own setup ceremony (create app, install deps, fill config, register commands, install launchd job). Document it.

- [ ] **Step 1: Read the current README to find the right insertion point**

Run:

```bash
grep -n '^## ' /Users/mac/personal/food/README.md
```

This lists the H2 sections. The new `## Discord bot` section should sit after the existing `## Customizing` section and before `## Troubleshooting`.

- [ ] **Step 2: Insert the new section**

Find the line `## Troubleshooting` in `/Users/mac/personal/food/README.md` and insert the following block immediately before it (and after the closing `---` of the Customizing section).

```markdown
## Discord bot (optional)

The nightly flow + `recipe --use` cover the local CLI. If you want to invoke the same capability from Discord on your phone, run the bot in `bot/`. It exposes three guild-scoped slash commands:

- `/cook ingredients: chicken, spinach` — single ad-hoc recipe (Phase 1 `--use` flow).
- `/today` — today's daily recipe. Fetches the cached file if present, otherwise generates it.
- `/tomorrow` — same for tomorrow.

Recipes arrive as messages in the channel where you ran the command.

### Setup

1. Create a Discord app at https://discord.com/developers/applications.
   - **Bot** tab → **Reset Token** → copy.
   - **General Information** tab → copy the **Application ID**.
   - (Server) Discord with Developer Mode on → right-click your server icon → **Copy Server ID**.
   - **OAuth2** → **URL Generator** → check `bot` and `applications.commands` → open the URL and invite the bot to your server.

2. Drop the three IDs into `config.sh` (alongside `DISCORD_WEBHOOK_URL` if you use it):

   ```sh
   DISCORD_BOT_TOKEN="..."
   DISCORD_APPLICATION_ID="..."
   DISCORD_GUILD_ID="..."
   ```

3. Install dependencies and register the commands:

   ```sh
   cd bot
   npm install
   node register-commands.js
   ```

   `register-commands.js` is idempotent — re-run it whenever you change command definitions.

4. Install the launchd supervisor (mirrors the daily-recipe job pattern):

   ```sh
   sed "s|__PROJECT_DIR__|$PWD/..|g" ../launchd/com.daily-recipe.bot.plist.template \
     > ~/Library/LaunchAgents/com.user.daily-recipe.bot.plist
   launchctl load ~/Library/LaunchAgents/com.user.daily-recipe.bot.plist
   ```

   The bot logs to `bot.out.log` and `bot.err.log` next to `generate-recipe.log`. `KeepAlive=true` restarts it automatically on crash.

   If your `node` binary lives somewhere other than `/opt/homebrew/bin/node`, edit the template before the `sed` line above (or fix the generated plist).

### Uninstall

```sh
launchctl unload ~/Library/LaunchAgents/com.user.daily-recipe.bot.plist
rm ~/Library/LaunchAgents/com.user.daily-recipe.bot.plist
```

---
```

The trailing `---` is important — it matches the existing pattern of section separators.

- [ ] **Step 3: Verify the section landed in the right place**

Run:

```bash
grep -n '^## ' /Users/mac/personal/food/README.md
```

Expected: the sections appear in this order: `## Features`, `## Requirements`, `## Install`, `## Usage`, `## File layout`, `## Editing your lists`, `## Customizing`, `## Discord bot (optional)`, `## Troubleshooting`, `## Uninstall`.

Also confirm fences balance:

```bash
grep -c '^```' /Users/mac/personal/food/README.md
```

Expected: an even number.

- [ ] **Step 4: Commit**

```bash
cd /Users/mac/personal/food
git add README.md
git commit -m "Document Discord bot setup in README"
```

---

## Task 6: Manual acceptance per spec

**Files:** none (verification only)

**Why:** Run the spec's full manual test plan end-to-end after all code is in place. This task requires real Discord credentials, so the user must set them up before this task runs.

If `DISCORD_BOT_TOKEN` is not configured in `config.sh`, **stop and ask the user** to complete the bot creation flow from README "Discord bot → Setup" steps 1–2, then resume.

- [ ] **Step 1: Verify config**

```bash
grep -E '^DISCORD_(BOT_TOKEN|APPLICATION_ID|GUILD_ID)=' /Users/mac/personal/food/config.sh
```

Expected: three lines, each with a non-empty quoted value. If any line is missing or empty, ask the user before proceeding.

- [ ] **Step 2: Register commands**

```bash
cd /Users/mac/personal/food/bot && node register-commands.js
```

Expected: `Registered 3 commands to guild <guild_id>`, exit 0.

- [ ] **Step 3: Foreground smoke run**

In one terminal:

```bash
cd /Users/mac/personal/food/bot && node index.js
```

Expected within ~5 seconds: `Logged in as <bot-username>`.

Leave this running. Switch to Discord in your phone/browser for the rest of this task. Use the configured guild.

- [ ] **Step 4: `/cook` happy path — single ingredient**

In Discord, type:

```
/cook ingredients: chicken
```

Expected within ~30 seconds:
- The bot shows "thinking..." then replies with a recipe.
- The first message starts with `# Recipe with chicken` (or, if chunking kicks in, the first chunk is the H2 dish header).
- "chicken" appears in the Ingredients section.

If the recipe is short (≤2000 chars), it arrives as a single message. If longer, the first message is the H1 + H2 head section and additional `## ` chunks arrive as follow-ups.

- [ ] **Step 5: `/cook` happy path — multiple ingredients**

```
/cook ingredients: chicken, spinach
```

Expected: both ingredients appear in the recipe. The first message begins with `# Recipe with chicken, spinach`.

- [ ] **Step 6: `/cook` empty-input rejection**

```
/cook ingredients:    
```

(Three spaces in the ingredients field.)

Expected: bot replies `Please provide at least one ingredient.`. No `claude` call is made — check `tail -5 generate-recipe.log` shows no new "Generating" line afterwards.

- [ ] **Step 7: `/today` fetch path (cached file exists)**

Ensure today's file exists:

```bash
ls /Users/mac/personal/food/recipes/$(date +%Y-%m-%d).md
```

If it doesn't exist, generate it first via the CLI:

```bash
cd /Users/mac/personal/food && ./generate-recipe.sh --today --force
```

Then in Discord:

```
/today
```

Expected: bot replies with the contents of `recipes/<today>.md`. Multiple `## Option` sections + one `## Recommended:` section, chunked across multiple messages.

- [ ] **Step 8: `/today` generation path (file missing)**

```bash
rm /Users/mac/personal/food/recipes/$(date +%Y-%m-%d).md
```

Then in Discord:

```
/today
```

Expected within ~30 seconds: bot generates a fresh recipe (you can confirm via `tail -10 generate-recipe.log` showing a new "Generating" line) and posts it.

- [ ] **Step 9: `/tomorrow` fetch path**

Ensure tomorrow's file exists (the launchd nightly may have already created it):

```bash
ls /Users/mac/personal/food/recipes/$(date -v+1d +%Y-%m-%d).md 2>/dev/null \
  || (cd /Users/mac/personal/food && ./generate-recipe.sh)
```

Then in Discord:

```
/tomorrow
```

Expected: bot posts the contents of `recipes/<tomorrow>.md`.

- [ ] **Step 10: Failure-path test**

Move `ingredients.txt` out of the way:

```bash
mv /Users/mac/personal/food/ingredients.txt /tmp/ingredients.txt.bak
rm /Users/mac/personal/food/recipes/$(date +%Y-%m-%d).md
```

Then in Discord:

```
/today
```

Expected: within ~10 seconds, bot replies `Recipe generation failed. Check generate-recipe.log and bot.err.log on the host.`. `bot.err.log` (or stderr in the foreground terminal) shows the spawned-process error.

Restore:

```bash
mv /tmp/ingredients.txt.bak /Users/mac/personal/food/ingredients.txt
```

- [ ] **Step 11: Stop the foreground bot**

In the bot's terminal, Ctrl-C.

- [ ] **Step 12: Install and validate the launchd supervisor**

```bash
sed "s|__PROJECT_DIR__|/Users/mac/personal/food|g" \
  /Users/mac/personal/food/launchd/com.daily-recipe.bot.plist.template \
  > ~/Library/LaunchAgents/com.user.daily-recipe.bot.plist
launchctl load ~/Library/LaunchAgents/com.user.daily-recipe.bot.plist
sleep 2
launchctl list | grep daily-recipe.bot
```

Expected: a line with a non-zero PID, e.g. `12345  0  com.user.daily-recipe.bot`.

Confirm the bot is logged in by checking `bot.out.log`:

```bash
tail -5 /Users/mac/personal/food/bot.out.log
```

Expected: `Logged in as <bot-username>`.

- [ ] **Step 13: KeepAlive test**

Find and kill the bot:

```bash
PID=$(launchctl list | awk '/daily-recipe.bot/ {print $1}')
echo "killing PID $PID"
kill "$PID"
sleep 3
launchctl list | grep daily-recipe.bot
```

Expected: a NEW non-zero PID — launchd restarted the process.

- [ ] **Step 14: Final smoke test under launchd**

In Discord:

```
/cook ingredients: chicken
```

Expected: recipe arrives. (Confirms the launchd-supervised instance routes correctly, has env vars, can spawn the script.)

- [ ] **Step 15: Report**

Summarize the 14 verification steps as pass/fail. If anything failed, do not declare the feature done — re-open the relevant task. If all passed, ask the user about release per project CLAUDE.md:

1. Commit (already done per-task).
2. Push to `origin`.
3. Add a semver tag — likely `v0.8.0 — add Discord bot listener`. Confirm the next version with `git tag -l --format='%(refname:short) %(subject)' --sort=-creatordate | head` before picking.

---

## Self-review notes

Spec coverage:
- Slash commands (3, names, options, semantics) → Tasks 2 (definitions), 3 (handlers).
- Command flow (defer, do work, post) → Task 3 handlers + dispatcher.
- Chunking helper → Task 3 `postMarkdown`.
- File layout → Tasks 1, 2, 3, 4.
- Configuration (three vars in config.sh, dotenv read) → Tasks 1 (example file) and 2 / 3 (consumers).
- Supervision (launchd template, KeepAlive, logs to bot.{out,err}.log) → Task 4.
- Slash command registration (one-shot script, manual run) → Task 2 (script), Task 5 (docs), Task 6 (run it).
- Error handling table (missing config / empty cook / spawn failure / unknown command) → Task 3 implementation + Task 6 Step 6, Step 10.
- Security (guild-scoped, no per-user/per-channel) → Task 2 registers to guild only; spec section is descriptive.
- Manual test plan → Task 6.
- Out-of-scope items → not implemented (by design).

No placeholders. Name consistency: `runScript`, `postMarkdown`, `reportFailure`, `handleCook`, `handleDaily`, `dateStr`, `PROJECT_DIR`, `RECIPES_DIR`, `SCRIPT`, `DISCORD_MSG_LIMIT` are defined in Task 3 and not referenced by other tasks. Command names `cook` / `today` / `tomorrow` match across Tasks 2 (definitions), 3 (dispatcher), 5 (docs), 6 (acceptance).
