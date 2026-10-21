import { resolve } from "node:path";
import { defineConfig } from "vite";

const preview = process.env.VITE_SLIDES_PREVIEW === "1";

export default defineConfig({
  base: process.env.VITE_BASE ?? "/",
  resolve: {
    // A slides preview build ships no compiler, so it must not need the
    // stage2-generated binding (src/generated/ is absent in a clean checkout).
    alias: preview
      ? [{ find: /^\.\/generated\/vibec\.component\.js$/, replacement: resolve(__dirname, "src/slides/preview-compiler.ts") }]
      : [],
  },
  server: {
    fs: {
      allow: [".."],
    },
  },
  build: {
    target: "esnext",
    rollupOptions: {
      input: {
        main: resolve(__dirname, "index.html"),
        slides: resolve(__dirname, "slides.html"),
      },
    },
  },
  optimizeDeps: {
    exclude: ["web-tree-sitter"],
  },
});
