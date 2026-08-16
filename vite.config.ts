// @lovable.dev/vite-tanstack-config already includes the following — do NOT add them manually
// or the app will break with duplicate plugins:
//   - TanStack devtools (dev-only, first), tanstackStart, viteReact, tailwindcss, tsConfigPaths,
//     nitro (build-only using cloudflare as a default target), VITE_* env injection, @ path alias,
//     React/TanStack dedupe, error logger plugins, and sandbox detection (port/host/strictPort).
// You can pass additional config via defineConfig({ vite: { ... }, etc... }) if needed.
import { loadEnv } from "vite";
import { defineConfig } from "@lovable.dev/vite-tanstack-config";

// Pick the deployment target at build time without editing this file.
// Example (VPS behind nginx): NITRO_PRESET=node-server npm run build
// When unset, the Lovable default (cloudflare-module) is used. See DEPLOYMENT.md.
// Note: static export (NITRO_PRESET=static) is NOT supported by this TanStack
// Start setup — use node-server or cloudflare-module instead.
const env = loadEnv("production", process.cwd(), "");
const nitroPreset = (env.NITRO_PRESET || process.env.NITRO_PRESET || "").trim();

export default defineConfig({
  ...(nitroPreset ? { nitro: { preset: nitroPreset } } : {}),
  tanstackStart: {
    // Redirect TanStack Start's bundled server entry to src/server.ts (our SSR error wrapper).
    // nitro/vite builds from this
    server: { entry: "server" },
  },
});
