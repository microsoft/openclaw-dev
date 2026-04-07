// Managed identity auth wrapper for OpenClaw + Azure OpenAI v1 API.
//
// Uses the same pattern as the Azure OpenAI Starter Kit:
// https://github.com/Azure-Samples/azure-openai-starter/blob/main/src/typescript/responses_example_entra.ts
//
// getBearerTokenProvider returns a callable that the OpenAI SDK invokes on each
// request, so tokens are refreshed automatically — no manual timer needed.
//
// This wrapper sets OPENAI_API_KEY to the token provider's initial value, then
// spawns OpenClaw. For continuous refresh, it periodically updates the env and
// sends SIGHUP to trigger OpenClaw's config-reload (which re-reads env).

import { DefaultAzureCredential, getBearerTokenProvider } from "@azure/identity";
import { spawn } from "node:child_process";

const SCOPE = "https://cognitiveservices.azure.com/.default";
const REFRESH_INTERVAL_MS = 45 * 60 * 1000; // refresh every 45 min (tokens last ~60 min)

const credential = new DefaultAzureCredential();
const tokenProvider = getBearerTokenProvider(credential, SCOPE);

let openclawProcess = null;

async function start() {
  // Get initial token via the provider (same pattern as the Azure sample)
  const initialToken = await tokenProvider();
  console.log("[auth] Obtained Entra ID token via getBearerTokenProvider");

  // Set it as OPENAI_API_KEY for the OpenClaw process
  process.env.OPENAI_API_KEY = initialToken;

  // Spawn OpenClaw gateway
  const args = process.argv.slice(2);
  openclawProcess = spawn("openclaw", ["gateway", ...args], {
    stdio: "inherit",
    env: process.env,
  });

  openclawProcess.on("exit", (code) => {
    process.exit(code ?? 0);
  });

  // Periodically refresh the token — getBearerTokenProvider handles caching
  // and only fetches a new token when the cached one is near expiry.
  setInterval(async () => {
    try {
      const freshToken = await tokenProvider();
      process.env.OPENAI_API_KEY = freshToken;
      // Signal OpenClaw to reload config (picks up new env value)
      if (openclawProcess && !openclawProcess.killed) {
        openclawProcess.kill("SIGHUP");
      }
      console.log("[auth] Token refreshed");
    } catch (err) {
      console.error("[auth] Token refresh failed:", err.message);
    }
  }, REFRESH_INTERVAL_MS);
}

// Forward termination signals to the child process
for (const sig of ["SIGTERM", "SIGINT"]) {
  process.on(sig, () => {
    if (openclawProcess) openclawProcess.kill(sig);
  });
}

start().catch((err) => {
  console.error("[auth] Fatal:", err);
  process.exit(1);
});
