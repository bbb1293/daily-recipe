const ALLOWED_MENTIONS = { parse: [], repliedUser: false };

function splitMessage(text, limit = 1900) {
  const parts = [];
  while (text.length > limit) {
    let end = text.lastIndexOf('\n', limit - 1) + 1 || limit;
    if (/[\uD800-\uDBFF]/.test(text[end - 1])) end -= 1;
    parts.push(text.slice(0, end));
    text = text.slice(end);
  }
  if (text) parts.push(text);
  return parts;
}

function createMessageHandler({ botId, guildId, processRequest, allowedUserIds = [], logger = console }) {
  let busy = false;
  return async (message) => {
    if (message.guildId !== guildId || message.author.bot || message.webhookId
        || (allowedUserIds.length && !allowedUserIds.includes(message.author.id))) return false;
    const mention = new RegExp(`<@!?${botId}>`, 'g');
    if (!mention.test(message.content)) return false;
    const request = message.content.replace(mention, '').trim();
    const reply = (content) => message.reply({ content, allowedMentions: ALLOWED_MENTIONS });
    if (!request) { await reply('Mention me with a request, such as “cook pork and cabbage” or “show my pantry”.'); return true; }
    if (busy) { await reply('I’m processing another kitchen request. Please try again when it finishes.'); return true; }
    busy = true;
    let progress;
    try {
      progress = await reply('Working on your kitchen request…');
      const chunks = splitMessage(await processRequest(request));
      await progress.edit({ content: chunks[0] || 'No result was returned.', allowedMentions: ALLOWED_MENTIONS });
      for (const content of chunks.slice(1)) await message.channel.send({ content, allowedMentions: ALLOWED_MENTIONS });
    } catch (error) {
      logger.error('natural-language request failed:', error);
      const failure = `${error.completedOutput ? `${error.completedOutput}\n\n` : ''}I couldn’t complete the request. Check the bot logs on the host and try again.`;
      if (progress) {
        const chunks = splitMessage(failure);
        await progress.edit({ content: chunks[0], allowedMentions: ALLOWED_MENTIONS });
        for (const content of chunks.slice(1)) await message.channel.send({ content, allowedMentions: ALLOWED_MENTIONS });
      }
    } finally {
      busy = false;
    }
    return true;
  };
}

module.exports = { createMessageHandler, splitMessage };
