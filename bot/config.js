const path = require('node:path');

require('dotenv').config({ path: path.join(__dirname, '..', 'config.sh') });

const REQUIRED = ['DISCORD_BOT_TOKEN', 'DISCORD_APPLICATION_ID', 'DISCORD_GUILD_ID'];
for (const key of REQUIRED) {
  if (!process.env[key]) {
    console.error(`missing required config: ${key}`);
    process.exit(1);
  }
}
