import { resolve } from "node:path";
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
