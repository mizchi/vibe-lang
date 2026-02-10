export type JsonValue =
  | string
  | number
  | boolean
  | null
  | JsonValue[]
  | { [key: string]: JsonValue };

export interface LspTransport {
  send(message: string): void | Promise<void>;
  onMessage(handler: (message: string) => void | Promise<void>): void | (() => void);
}

export type LspMessageHandler =
  (message: string | JsonValue) =>
    | void
    | null
    | string
    | JsonValue
    | Promise<void | null | string | JsonValue>;

export function bindLspTransport(transport: LspTransport, handler: LspMessageHandler): () => void;

export function createLspBridge(handler: LspMessageHandler): {
  handle(message: string | JsonValue): Promise<string | JsonValue | null>;
  bind(transport: LspTransport): () => void;
};

export function createWebSocketTransport(ws: {
  send(data: string): void;
  addEventListener(type: "message", listener: (event: { data: string }) => void): void;
  removeEventListener(type: "message", listener: (event: { data: string }) => void): void;
}): LspTransport;
