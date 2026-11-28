import { defineConfig } from "vite";
import react from "@vitejs/plugin-react";

// Tauri 开发服务器固定端口，避免 Rust 侧 devUrl 对不上。
export default defineConfig({
  plugins: [react()],
  clearScreen: false,
  server: {
    port: 1420,
    strictPort: true,
    watch: {
      ignored: ["**/src-tauri/**"],
    },
  },
  envPrefix: ["VITE_", "TAURI_"],
  build: {
    target: "chrome105",
    sourcemap: false,
  },
});
