export type JSONValue = string | number | boolean | null | JSONValue[] | { [key: string]: JSONValue };
export interface Host {
  clipboard: { writeText(text: string): Promise<void> };
  url: { open(url: string): Promise<void> };
  settings: { get(key: string): Promise<JSONValue> };
  storage: { get(key: string): Promise<JSONValue>; set(key: string, value: JSONValue): Promise<void> };
  status: { show(message: string): Promise<void> };
}
export interface Invocation { signal: AbortSignal }
export interface CommandInput extends Invocation { argument: string }
export interface SearchInput extends Invocation { query: string }
export interface ActionInput extends Invocation { arguments: JSONValue }
export interface Completion { message?: string }
export interface ResultAction { id: string; title: string; arguments?: JSONValue }
export interface SearchItem { id: string; title: string; subtitle?: string; symbol?: string; actions: ResultAction[] }
export interface SearchResult { items: SearchItem[] }
export type Handler<Input, Output> = (input: Input, host: Host) => Output | Promise<Output>;
export interface Plugin {
  commands?: Record<string, Handler<CommandInput, Completion | void>>;
  searchProviders?: Record<string, Handler<SearchInput, SearchResult>>;
  actions?: Record<string, Handler<ActionInput, Completion | void>>;
}
export declare function definePlugin<T extends Plugin>(plugin: T): T;
