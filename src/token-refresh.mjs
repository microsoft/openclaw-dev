// Token-refresh wrapper for OpenClaw with Azure OpenAI managed identity auth.
// Fetches an Entra ID token via DefaultAzureCredential, sets it as OPENAI_API_KEY,
// spawns OpenClaw gateway, and refreshes the token before expiry.

import { DefaultAzureCredential } from "@azure/identity";
import { spawn } from "node:child_process";

const SCOPE = "https://cognitiveservices.azure.com/.default";
const REFRESH_MARGIN_MS = 5 * 60 * 1000; // refresh 5 min before expiry

const credential = new DefaultAzureCredential();
let openclawProcess = null;

async function getToken() {
  const token = await credential.getToken(SCOPE);
  return token;
}

async function start() {
  const token = await getToken();
  console.log("[token-refresh] Obtained Entra ID token, expires:", token.expiresOnTimestamp
    ? new Date(token.expiresOnTimestamp).toISOString()
    : "unknown");

  // Set the token as the OpenAI API key — the v1 API accepts bearer tokens here
  process.env.OPENAI_API_KEY = token.token;

  // Spawn OpenClaw gateway
  const args = process.argv.slice(2); // forward any CLI args
  openclawProcess = spawn("openclaw", ["gateway", ...args], {
    stdio: "inherit",
    env: process.env,
  });

  openclawProcess.on("exit", (code) => {
    process.exit(code ?? 0);
  });

  // Schedule token refresh
  scheduleRefresh(token.expiresOnTimestamp);
}

function scheduleRefresh(expiresOnTimestamp) {
  const now = Date.now();
  const refreshIn = Math.max((expiresOnTimestamp - now) - REFRESH_MARGIN_MS, 30_000);
  console.log(`[token-refresh] Next refresh in ${Math.round(refreshIn / 1000)}s`);

  setTimeout(async () => {
    try {
      const token = await getToken();
      process.env.OPENAI_API_KEY = token.token;
      console.log("[token-refresh] Token refreshed, expires:", new Date(token.expiresOnTimestamp).toISOString());
      scheduleRefresh(token.expiresOnTimestamp);
    } catch (err) {
      console.error("[token-refresh] Failed to refresh token:", err.message);
      // Retry in 60s
      setTimeout(() => scheduleRefresh(Date.now() + 10 * 60 * 1000), 60_000);
    }
  }, refreshIn);
}

// Forward signals to the child process
for (const sig of ["SIGTERM", "SIGINT"]) {
  process.on(sig, () => {
    if (openclawProcess) openclawProcess.kill(sig);
  });
}

start().catch((err) => {
  console.error("[token-refresh] Fatal:", err);
  process.exit(1);
});
