import type * as monaco from "monaco-editor";

// web-tree-sitter types don't export cleanly, use dynamic import
let Parser: any;

const TOKEN_MAP: Record<string, string> = {
  keyword: "keyword",
  "keyword.control.conditional": "keyword",
  "keyword.control.repeat": "keyword",
  "keyword.control.return": "keyword",
  "keyword.control.exception": "keyword",
  "keyword.control.import": "keyword",
  "keyword.storage.type": "keyword",
  "keyword.storage.modifier": "keyword",
  type: "type",
  "type.identifier": "type",
  constructor: "type",
  function: "function",
  "function.call": "function",
  "variable.parameter": "parameter",
  variable: "variable",
  property: "property",
  module: "namespace",
  comment: "comment",
  string: "string",
  "string.escape": "string",
  number: "number",
  "number.float": "number",
  constant: "keyword",
  operator: "operator",
};

let parserInstance: any = null;
let highlightQuery: any = null;

export async function initTreeSitter(wasmPath: string): Promise<void> {
  const mod = await import("web-tree-sitter");
  Parser = mod.Parser ?? mod.default?.Parser ?? mod.default ?? mod;
  const Language = mod.Language ?? mod.default?.Language ?? Parser.Language;
  const Query = mod.Query ?? mod.default?.Query;

  const base = wasmPath.substring(0, wasmPath.lastIndexOf("/") + 1);
  await Parser.init({
    locateFile: (scriptName: string) => `${base}${scriptName}`,
  });
  parserInstance = new Parser();
  const vibeLanguage = await Language.load(wasmPath);
  parserInstance.setLanguage(vibeLanguage);

  const highlightsSrc = await fetch(
    new URL("../treesitter-queries/highlights.scm", import.meta.url).href,
  ).then((r: Response) => r.text());
  highlightQuery = new Query(vibeLanguage, highlightsSrc);
}

const SEMANTIC_TOKEN_TYPES = [
  "comment",
  "keyword",
  "string",
  "number",
  "type",
  "function",
  "variable",
  "parameter",
  "property",
  "namespace",
  "operator",
];

const SEMANTIC_TOKEN_MODIFIERS = ["declaration", "definition"];

export function getSemanticTokensLegend(): monaco.languages.SemanticTokensLegend {
  return {
    tokenTypes: SEMANTIC_TOKEN_TYPES,
    tokenModifiers: SEMANTIC_TOKEN_MODIFIERS,
  };
}

type CaptureResult = {
  name: string;
  node: {
    startPosition: { row: number; column: number };
    endPosition: { row: number; column: number };
  };
};

export function computeSemanticTokens(code: string): { data: number[] } | null {
  if (!parserInstance || !highlightQuery) return null;

  const tree = parserInstance.parse(code);
  const captures: CaptureResult[] = highlightQuery.captures(tree.rootNode);

  captures.sort((a, b) => {
    const aStart = a.node.startPosition;
    const bStart = b.node.startPosition;
    if (aStart.row !== bStart.row) return aStart.row - bStart.row;
    return aStart.column - bStart.column;
  });

  const seen = new Set<string>();
  const filtered: CaptureResult[] = [];
  for (const cap of captures) {
    const key = `${cap.node.startPosition.row}:${cap.node.startPosition.column}:${cap.node.endPosition.row}:${cap.node.endPosition.column}`;
    if (!seen.has(key)) {
      seen.add(key);
      filtered.push(cap);
    }
  }

  const data: number[] = [];
  let prevLine = 0;
  let prevChar = 0;

  for (const cap of filtered) {
    const tokenType = TOKEN_MAP[cap.name];
    if (!tokenType) continue;

    const typeIndex = SEMANTIC_TOKEN_TYPES.indexOf(tokenType);
    if (typeIndex < 0) continue;

    const startRow = cap.node.startPosition.row;
    const startCol = cap.node.startPosition.column;
    const endRow = cap.node.endPosition.row;
    const endCol = cap.node.endPosition.column;

    if (startRow !== endRow) continue;

    const length = endCol - startCol;
    if (length <= 0) continue;

    const deltaLine = startRow - prevLine;
    const deltaStart = deltaLine === 0 ? startCol - prevChar : startCol;

    data.push(deltaLine, deltaStart, length, typeIndex, 0);

    prevLine = startRow;
    prevChar = startCol;
  }

  tree.delete();
  return { data };
}
