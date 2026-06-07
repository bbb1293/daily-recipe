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
const KITCHEN_SCRIPT = path.join(PROJECT_DIR, 'kitchen.sh');
const DISCORD_MSG_LIMIT = 2000;

function dateStr(offsetDays = 0) {
  const d = new Date();
  d.setDate(d.getDate() + offsetDays);
  const year = d.getFullYear();
  const month = String(d.getMonth() + 1).padStart(2, '0');
  const day = String(d.getDate()).padStart(2, '0');
  return `${year}-${month}-${day}`; // local YYYY-MM-DD (matches `date +%Y-%m-%d`)
}

function runScript(args, script = SCRIPT) {
  return new Promise((resolve, reject) => {
    let stdout = '';
    let stderr = '';
    const child = spawn(script, args, { cwd: PROJECT_DIR });
    child.stdout.on('data', (chunk) => {
      stdout += chunk.toString();
    });
    child.stderr.on('data', (chunk) => {
      stderr += chunk.toString();
    });
    child.on('close', (code) => {
      if (code === 0) resolve(stdout);
      else reject(new Error(`${path.basename(script)} exited ${code}\nstderr: ${stderr.slice(-2000)}`));
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
  const chunks = markdown.split(/\n(?=## )/);
  let first = true;
  for (const chunk of chunks) {
    let text = chunk;
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

function splitItems(raw) {
  return raw
    .split(',')
    .map((s) => s.trim())
    .filter(Boolean);
}

async function handleCook(interaction) {
  const items = splitItems(interaction.options.getString('ingredients', true));
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

async function handleKitchen(interaction) {
  const sub = interaction.options.getSubcommand();
  const args = [];
  switch (sub) {
    case 'list': {
      args.push('list');
      const which = interaction.options.getString('which');
      if (which) args.push(which);
      break;
    }
    case 'add': {
      const list = interaction.options.getString('list', true);
      const items = splitItems(interaction.options.getString('items', true));
      if (items.length === 0) {
        await interaction.editReply('Please provide at least one item.');
        return;
      }
      args.push('add', list, ...items);
      if (interaction.options.getBoolean('urgent')) args.push('--urgent');
      break;
    }
    case 'remove': {
      const list = interaction.options.getString('list', true);
      const items = splitItems(interaction.options.getString('items', true));
      if (items.length === 0) {
        await interaction.editReply('Please provide at least one item.');
        return;
      }
      args.push('remove', list, ...items);
      break;
    }
    case 'urgent':
    case 'unurgent': {
      const items = splitItems(interaction.options.getString('items', true));
      if (items.length === 0) {
        await interaction.editReply('Please provide at least one item.');
        return;
      }
      args.push(sub, ...items);
      break;
    }
    default:
      await interaction.editReply(`Unknown subcommand: ${sub}`);
      return;
  }
  try {
    const stdout = await runScript(args, KITCHEN_SCRIPT);
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
      // --print forces INTERACTIVE=true in the script, which skips the
      // AppleScript notify_dialog that would otherwise block the spawn
      // until the user clicks Later/Open on the host's desktop.
      const args = offsetDays === 0 ? ['--today', '--print'] : ['--print'];
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

client.once('clientReady', () => {
  console.log(`Logged in as ${client.user.tag}`);
});

client.on('interactionCreate', async (interaction) => {
  if (!interaction.isChatInputCommand()) return;
  try {
    await interaction.deferReply();
    switch (interaction.commandName) {
      case 'cook':
        await handleCook(interaction);
        break;
      case 'kitchen':
        await handleKitchen(interaction);
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
