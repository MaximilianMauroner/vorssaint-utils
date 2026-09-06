import { definePlugin, type SearchItem } from '@vorssaint/plugin-sdk';

export default definePlugin({
  searchProviders: {
    wikipedia: async ({ query, signal }) => {
      if (!query.trim()) return { items: [] };
      const url = new URL('https://en.wikipedia.org/w/api.php');
      url.search = new URLSearchParams({ action: 'opensearch', search: query, limit: '8', format: 'json' }).toString();
      const response = await fetch(url, { signal });
      if (!response.ok) throw new Error(`Wikipedia returned HTTP ${response.status}`);
      const data: unknown = await response.json();
      if (!Array.isArray(data) || !Array.isArray(data[1]) || !Array.isArray(data[3])) throw new Error('Invalid Wikipedia response');
      const titles: unknown[] = data[1];
      const urls: unknown[] = data[3];
      const items: SearchItem[] = [];
      for (const [index, title] of titles.entries()) {
        const target = urls[index];
        if (typeof title !== 'string' || typeof target !== 'string' || !target.startsWith('https://en.wikipedia.org/')) continue;
        items.push({ id: `article-${index}`, title, symbol: 'globe', actions: [{ id: 'open', title: 'Open article', arguments: { url: target } }] });
      }
      return { items };
    },
  },
  actions: {
    open: async ({ arguments: args }, host) => {
      if (!args || typeof args !== 'object' || Array.isArray(args) || typeof args.url !== 'string' || !args.url.startsWith('https://en.wikipedia.org/')) throw new Error('Invalid article URL');
      await host.url.open(args.url);
      return { message: 'Opened article' };
    },
  },
});
