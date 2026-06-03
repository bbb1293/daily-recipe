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
