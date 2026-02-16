export type JsonValue =
  | string
  | number
  | boolean
  | null
  | JsonValue[]
  | { [key: string]: JsonValue };

export interface Span {
  start: number;
  end: number;
}

export interface VibeInitRequest {
  prelude?: string;
  kv?: Record<string, string>;
}

export interface VibeInitOkResult {
  ok: true;
  prelude: boolean;
  kv_count: number;
}

export interface VibeInitErrorResult {
  ok: false;
  error: string;
}

export type VibeInitResult = VibeInitOkResult | VibeInitErrorResult;

export interface Diagnostic {
  stage: string;
  message: string;
  span: Span | null;
  hint?: string;
  note?: string;
}

export interface CheckResult {
  ok: boolean;
  error_count: number;
  warning_count: number;
  diagnostics: Diagnostic[];
}

export interface FormatResult {
  ok: boolean;
  formatted: string;
  changed: boolean;
}

export interface IdeSymbolEntry {
  name: string;
  kind: string;
  signature: string;
  path: string;
  span: Span;
  line: number;
  column: number;
  line_text: string;
}

export interface IdeProjectRequestBase {
  entry: string;
  files: Record<string, string>;
  path?: string;
}

export interface IdeSingleFileRequestBase {
  source: string;
  path?: string;
}

export type IdeOutlineRequest =
  | IdeSingleFileRequestBase
  | IdeProjectRequestBase;

export type IdePeekDefRequest =
  & (IdeSingleFileRequestBase | IdeProjectRequestBase)
  & {
    symbol: string;
  };

export type IdeSearchRequest =
  & (IdeSingleFileRequestBase | IdeProjectRequestBase)
  & {
    query: string;
  };

export interface IdeErrorResult {
  ok: false;
  error: string;
  diagnostics?: Diagnostic[];
}

export interface IdeOutlineOkResult {
  ok: true;
  path: string;
  symbols: IdeSymbolEntry[];
}

export interface IdePeekDefOkResult {
  ok: true;
  path: string;
  symbol: string;
  matches: IdeSymbolEntry[];
}

export interface IdeSearchOkResult {
  ok: true;
  path: string;
  query: string;
  matches: IdeSymbolEntry[];
}

export type IdeOutlineResult = IdeOutlineOkResult | IdeErrorResult;
export type IdePeekDefResult = IdePeekDefOkResult | IdeErrorResult;
export type IdeSearchResult = IdeSearchOkResult | IdeErrorResult;

export interface EvalRequest {
  source: string;
}

export interface EvalOkResult {
  ok: true;
  value: string | null;
  value_type: string;
  diagnostics: Diagnostic[];
}

export interface EvalErrorResult {
  ok: false;
  diagnostics: Diagnostic[];
}

export type EvalResult = EvalOkResult | EvalErrorResult;

export interface EvalResetResult {
  ok: true;
}

export interface VibeServiceOptions {
  wasmPath?: string;
  inputPtr?: number;
  outputPtr?: number;
  outputCap?: number;
  imports?: WebAssembly.Imports;
  bootstrap?: VibeInitRequest;
}

export interface VibeService {
  wasmPath: string;
  instance: WebAssembly.Instance;
  memory: WebAssembly.Memory;
  rawInit(request: VibeInitRequest | string): Promise<string>;
  init(request: VibeInitRequest): Promise<VibeInitResult>;
  rawCheck(source: string): Promise<string>;
  rawCheckProject(project: ProjectCheckRequest | string): Promise<string>;
  rawFormat(source: string): Promise<string>;
  rawIdeOutline(request: IdeOutlineRequest | string): Promise<string>;
  rawIdePeekDef(request: IdePeekDefRequest | string): Promise<string>;
  rawIdeSearch(request: IdeSearchRequest | string): Promise<string>;
  check(source: string): Promise<CheckResult>;
  format(source: string): Promise<FormatResult>;
  ideOutline(request: IdeOutlineRequest): Promise<IdeOutlineResult>;
  idePeekDef(request: IdePeekDefRequest): Promise<IdePeekDefResult>;
  ideSearch(request: IdeSearchRequest): Promise<IdeSearchResult>;
  checkProject(project: ProjectCheckRequest): Promise<ProjectCheckResult>;
  rawEval(request: EvalRequest | string): Promise<string>;
  rawEvalReset(request?: object | string): Promise<string>;
  eval(request: EvalRequest): Promise<EvalResult>;
  evalReset(request?: object): Promise<EvalResetResult>;
}

export function createVibeService(
  options?: VibeServiceOptions,
): Promise<VibeService>;

export interface ProjectCheckRequest {
  entry: string;
  files: Record<string, string>;
}

export interface ProjectCheckResult extends CheckResult {
  entry: string;
  unsupported_imports: boolean;
}

export interface LspTransport {
  send(message: string): void | Promise<void>;
  onMessage(
    handler: (message: string) => void | Promise<void>,
  ): void | (() => void);
}

export type LspMessageHandler = (message: string | JsonValue) =>
  | void
  | null
  | string
  | JsonValue
  | Promise<void | null | string | JsonValue>;

export function bindLspTransport(
  transport: LspTransport,
  handler: LspMessageHandler,
): () => void;

export function createLspBridge(handler: LspMessageHandler): {
  handle(message: string | JsonValue): Promise<string | JsonValue | null>;
  bind(transport: LspTransport): () => void;
};

export function createWebSocketTransport(ws: {
  send(data: string): void;
  addEventListener(
    type: "message",
    listener: (event: { data: string }) => void,
  ): void;
  removeEventListener(
    type: "message",
    listener: (event: { data: string }) => void,
  ): void;
}): LspTransport;
