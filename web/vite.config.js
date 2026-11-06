import { defineConfig } from "vite";
import react from "@vitejs/plugin-react";

// In development, /api is proxied to the API on :8080. In production, Nginx
// serves the built files from dist/ and proxies /api to the API.
export default defineConfig({
  plugins: [react()],
  server: {
    port: 5173,
    proxy: { "/api": "http://127.0.0.1:8080" },
  },
});
