// Test script: sends a message to the OpenClaw gateway and prints the response.
// Usage: node test-agent.mjs <FQDN> <password> <message>
import { createHash } from "node:crypto";

const FQDN = process.argv[2] || "openclaw-5kylywa2qbx3s.bluecoast-e96f2393.eastus2.azurecontainerapps.io";
const PASSWORD = process.argv[3] || "openclaw-azure-test";
const MESSAGE = process.argv[4] || "Hello! What are you? Reply in one sentence.";

const ws = new WebSocket(`wss://${FQDN}/ws?password=${encodeURIComponent(PASSWORD)}`);
let responseText = "";

ws.onopen = () => console.log("[ws] connected");

ws.onmessage = (event) => {
  const raw = event.data;
  console.log("[ws] <<", raw.substring(0, 500));
  const msg = JSON.parse(raw);

  if (msg.type === "event" && msg.event === "connect.challenge") {
    const nonce = msg.payload.nonce;
    // Try HMAC-SHA256 challenge-response
    const hmac = createHash("sha256").update(nonce + ":" + PASSWORD).digest("hex");
    const authMsg = { type: "auth", nonce, password: PASSWORD, response: hmac };
    console.log("[ws] >> auth:", JSON.stringify(authMsg));
    ws.send(JSON.stringify(authMsg));
  } else if (msg.type === "event" && msg.event === "connect.authenticated") {
    console.log("[ws] authenticated — sending message...");
    ws.send(JSON.stringify({
      type: "conversationMessage",
      role: "human",
      content: MESSAGE,
      conversationId: "test-azure-" + Date.now(),
    }));
  } else if (msg.type === "event" && msg.event === "agent.message.delta") {
    // Streaming token
    process.stdout.write(msg.payload?.delta || "");
    responseText += msg.payload?.delta || "";
  } else if (msg.type === "event" && msg.event === "agent.message.complete") {
    console.log("\n\n[ws] === Agent response complete ===");
    ws.close();
  } else if (msg.type === "event" && msg.event === "agent.turn.complete") {
    if (!responseText) {
      console.log("[ws] Turn complete (no streaming delta received)");
      console.log("[ws] Full message payload:", JSON.stringify(msg.payload, null, 2));
    }
    ws.close();
  } else if (msg.type === "error") {
    console.error("[ws] ERROR:", JSON.stringify(msg));
    ws.close();
  } else {
    // Log other events for debugging
    const summary = msg.event || msg.type;
    if (!["heartbeat", "agent.message.delta"].includes(summary)) {
      console.log(`[ws] ${summary}:`, JSON.stringify(msg.payload || {}).substring(0, 200));
    }
  }
};

ws.onerror = (err) => { console.error("[ws] error:", err.message); process.exit(1); };
ws.onclose = () => { console.log("[ws] closed"); process.exit(0); };

// Timeout after 30s
setTimeout(() => { console.log("[ws] timeout"); ws.close(); process.exit(1); }, 30000);
