import { defineConfig } from "vite";

export default defineConfig({
  base: process.env.VITE_BASE ?? "/",
  server: {
    fs: {
      allow: [".."],
    },
  },
  build: {
    target: "esnext",
  },
  optimizeDeps: {
    exclude: ["web-tree-sitter"],
  },
});
