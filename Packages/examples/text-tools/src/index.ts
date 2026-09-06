import { definePlugin } from '@vorssaint/plugin-sdk';

export default definePlugin({
  commands: {
    uppercase: async ({ argument }, host) => {
      await host.clipboard.writeText(argument.toUpperCase());
      return { message: 'Copied uppercase text' };
    },
  },
});
