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
  {
    name: 'kitchen',
    description: 'Manage your ingredients and pantry lists',
    options: [
      {
        type: 1, // SUB_COMMAND
        name: 'list',
        description: 'Show current ingredients and/or pantry',
        options: [
          {
            type: 3, // STRING
            name: 'which',
            description: 'Which list (default: both)',
            required: false,
            choices: [
              { name: 'ingredients', value: 'ingredients' },
              { name: 'pantry', value: 'pantry' },
            ],
          },
        ],
      },
      {
        type: 1,
        name: 'add',
        description: 'Add items to a list',
        options: [
          {
            type: 3,
            name: 'list',
            description: 'Which list to add to',
            required: true,
            choices: [
              { name: 'ingredients', value: 'ingredients' },
              { name: 'pantry', value: 'pantry' },
            ],
          },
          {
            type: 3,
            name: 'items',
            description: 'Comma-separated, e.g. "chicken thighs, spinach"',
            required: true,
          },
          {
            type: 5, // BOOLEAN
            name: 'urgent',
            description: 'Mark these as urgent (ingredients only)',
            required: false,
          },
        ],
      },
      {
        type: 1,
        name: 'remove',
        description: 'Remove items from a list',
        options: [
          {
            type: 3,
            name: 'list',
            description: 'Which list to remove from',
            required: true,
            choices: [
              { name: 'ingredients', value: 'ingredients' },
              { name: 'pantry', value: 'pantry' },
            ],
          },
          {
            type: 3,
            name: 'items',
            description: 'Comma-separated items to remove',
            required: true,
          },
        ],
      },
      {
        type: 1,
        name: 'urgent',
        description: 'Mark ingredients as urgent',
        options: [
          {
            type: 3,
            name: 'items',
            description: 'Comma-separated ingredients to mark urgent',
            required: true,
          },
        ],
      },
      {
        type: 1,
        name: 'unurgent',
        description: 'Clear urgent from ingredients',
        options: [
          {
            type: 3,
            name: 'items',
            description: 'Comma-separated ingredients to clear',
            required: true,
          },
        ],
      },
    ],
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
