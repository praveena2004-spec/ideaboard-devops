import { defineConfig } from "vite";
import react from "@vitejs/plugin-react";

// In local dev (`npm run dev`) /api calls are proxied to the backend, so the
// browser sees one origin, the same as behind nginx in Docker/Kubernetes.
// VITE_PROXY_TARGET lets you point at a different backend.
export default defineConfig({
  plugins: [react()],
  server: {
    port: 5173,
    proxy: {
      "/api": process.env.VITE_PROXY_TARGET || "http://localhost:8000",
    },
  },
});
