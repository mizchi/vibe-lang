// Stands in for the generated browser compiler in a preview build
// (`pnpm build:slides-preview`), which needs no stage2. The deck never calls
// it in preview mode; if anything does, it fails loudly instead of answering.
export function compile(_payload: string, _mode: string): string {
  throw new Error("This preview build does not include the vibe compiler.");
}
