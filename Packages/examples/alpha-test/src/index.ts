import { definePlugin, type JSONValue, type SearchItem } from '@vorssaint/plugin-sdk';

const docsURL = 'https://github.com/vorssaint/vorssaint-utils/blob/alpha/docs/PLUGINS.md';

function record(value: JSONValue): Record<string, JSONValue> {
  if (!value || typeof value !== 'object' || Array.isArray(value)) throw new Error('Expected action arguments');
  return value;
}

export default definePlugin({
  commands: {
    'run-all': async ({ argument, signal }, host) => {
      signal.throwIfAborted();
      const label = await host.settings.get('label');
      const enabled = await host.settings.get('enabled');
      const count = await host.settings.get('count');
      const previous = await host.storage.get('lastRun');
      const result: JSONValue = { argument, label, enabled, count, previous };
      await host.storage.set('lastRun', result);
      await host.clipboard.writeText(JSON.stringify(result, null, 2));
      await host.status.show('All capability checks completed');
      return { message: 'Settings read, storage round-tripped, status shown, and result copied' };
    },
    copy: async ({ argument }, host) => {
      await host.clipboard.writeText(argument || 'Vorssaint plugin clipboard test');
      return { message: 'Copied test text' };
    },
    'open-docs': async (_input, host) => {
      await host.url.open(docsURL);
      return { message: 'Opened plugin documentation' };
    },
    'show-status': async (_input, host) => {
      await host.status.show('Status bridge is working');
      return { message: 'Status sent' };
    },
    storage: async ({ argument }, host) => {
      const previous = await host.storage.get('manual');
      await host.storage.set('manual', { text: argument, previous });
      return { message: `Stored value; previous value was ${JSON.stringify(previous)}` };
    },
    'no-message': async () => {},
    'expected-error': async () => {
      throw new Error('Expected alpha test error');
    },
  },
  searchProviders: {
    'all-options': async ({ query, signal }) => {
      if (query === 'slow') {
        await new Promise<void>((_resolve, reject) => {
          signal.addEventListener('abort', () => reject(new Error('Search canceled as expected')), { once: true });
        });
      }
      if (query === 'error') throw new Error('Expected alpha search error');
      if (query === 'empty') return { items: [] };
      if (query === 'fetch') {
        const response = await fetch('https://example.com', { signal });
        return {
          items: [{
            id: 'fetch-result',
            title: `Fetch returned HTTP ${response.status}`,
            subtitle: 'Node fetch and network access worked',
            symbol: 'network',
            actions: [{ id: 'show-arguments', title: 'Show result', arguments: { status: response.status } }],
          }],
        };
      }
      const payload: JSONValue = {
        query,
        string: 'text',
        number: 42,
        boolean: true,
        null: null,
        array: ['one', 2, false, null],
      };
      const items: SearchItem[] = [
        {
          id: 'complete-row',
          title: query || 'Complete result row',
          subtitle: 'Subtitle, SF Symbol, and three actions',
          symbol: 'puzzlepiece.extension.fill',
          actions: [
            { id: 'show-arguments', title: 'Show arguments', arguments: payload },
            { id: 'copy-arguments', title: 'Copy arguments', arguments: payload },
            { id: 'store-arguments', title: 'Store arguments', arguments: payload },
          ],
        },
        {
          id: 'minimal-row',
          title: 'Minimal result row',
          actions: [{ id: 'open-docs', title: 'Open plugin docs', arguments: null }],
        },
      ];
      return { items };
    },
  },
  actions: {
    'show-arguments': async ({ arguments: value }, host) => {
      await host.status.show(`Arguments: ${JSON.stringify(value)}`);
      return { message: 'Displayed action arguments' };
    },
    'copy-arguments': async ({ arguments: value }, host) => {
      await host.clipboard.writeText(JSON.stringify(value, null, 2));
      return { message: 'Copied action arguments' };
    },
    'store-arguments': async ({ arguments: value }, host) => {
      const args = record(value);
      await host.storage.set('searchAction', args);
      const stored = await host.storage.get('searchAction');
      return { message: stored ? 'Stored and read action arguments' : 'Storage returned no value' };
    },
    'open-docs': async (_input, host) => {
      await host.url.open(docsURL);
      return { message: 'Opened plugin documentation' };
    },
  },
});
