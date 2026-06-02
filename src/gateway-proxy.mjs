// gateway-proxy.mjs — tiny reverse proxy that sits in front of openclaw.
//
// Why this exists:
//   ACA only exposes ONE ingress port per container app (18789 here).
//   openclaw gateway listens on 18789 for the Control UI / WebChat / API.
//   The Microsoft Teams plugin (@openclaw/msteams) binds its OWN Express
//   server on port 3978 to receive Bot Framework webhooks at /api/messages.
//   Without a proxy, Bot Framework's POST to https://<host>/api/messages
//   reaches the gateway and 404s — the msteams plugin's 3978 socket is
//   unreachable from outside.
//
// What this does:
//   - Listens on 18789 (the ACA ingress targetPort).
//   - Routes POST /api/messages to 127.0.0.1:3978 (msteams plugin).
//   - Routes everything else (including WebSocket upgrades for the Control
//     UI) to 127.0.0.1:18788 (openclaw gateway).
//
// entrypoint.sh moves the openclaw gateway to internal port 18788 and
// starts this proxy on 18789 before the gateway is ready. The proxy
// returns 502 until the upstream comes up — Bot Framework retries.

import http from "node:http";
import httpProxy from "http-proxy";

const PROXY_PORT = Number(process.env.GATEWAY_PROXY_PORT ?? 18789);
const GATEWAY_UPSTREAM = process.env.GATEWAY_UPSTREAM ?? "http://127.0.0.1:18788";
const MSTEAMS_UPSTREAM = process.env.MSTEAMS_UPSTREAM ?? "http://127.0.0.1:3978";

const gatewayProxy = httpProxy.createProxyServer({
    target: GATEWAY_UPSTREAM,
    ws: true,
    xfwd: true,
    changeOrigin: false,
});

const msteamsProxy = httpProxy.createProxyServer({
    target: MSTEAMS_UPSTREAM,
    xfwd: true,
    changeOrigin: false,
});

function onProxyError(label) {
    return (err, _req, res) => {
        console.error(`[gateway-proxy] ${label} upstream error: ${err?.message ?? err}`);
        if (res && typeof res.writeHead === "function" && !res.headersSent) {
            res.writeHead(502, { "Content-Type": "text/plain" });
            res.end("Bad Gateway");
        } else if (res && typeof res.end === "function") {
            try { res.end(); } catch { /* socket already closed */ }
        }
    };
}

gatewayProxy.on("error", onProxyError("gateway"));
msteamsProxy.on("error", onProxyError("msteams"));

function requestPath(url) {
    if (!url) return "";
    try {
        return new URL(url, "http://gateway-proxy.local").pathname;
    } catch {
        return "";
    }
}

function isBotFrameworkPath(url) {
    return requestPath(url) === "/api/messages";
}

function rejectUpgrade(socket) {
    try {
        if (socket.writable) {
            socket.end("HTTP/1.1 400 Bad Request\r\nConnection: close\r\nContent-Length: 0\r\n\r\n");
        } else {
            socket.destroy();
        }
    } catch {
        try { socket.destroy(); } catch { /* already closed */ }
    }
}

const server = http.createServer((req, res) => {
    if (isBotFrameworkPath(req.url)) {
        if (req.method !== "POST") {
            res.writeHead(405, { "Allow": "POST", "Content-Type": "text/plain" });
            res.end("Method Not Allowed");
            return;
        }
        msteamsProxy.web(req, res);
    } else {
        gatewayProxy.web(req, res);
    }
});

server.on("upgrade", (req, socket, head) => {
    // Bot Framework webhook delivery is HTTPS POST-only.
    if (isBotFrameworkPath(req.url)) {
        rejectUpgrade(socket);
        return;
    }
    // All other WS upgrades go to the gateway, which enforces its own token check.
    gatewayProxy.ws(req, socket, head);
});

server.on("clientError", (err, socket) => {
    if (socket.writable) {
        socket.end("HTTP/1.1 400 Bad Request\r\n\r\n");
    }
});

server.listen(PROXY_PORT, "0.0.0.0", () => {
    console.log(`[gateway-proxy] listening on 0.0.0.0:${PROXY_PORT}`);
    console.log(`[gateway-proxy]   /api/messages -> ${MSTEAMS_UPSTREAM}`);
    console.log(`[gateway-proxy]   *             -> ${GATEWAY_UPSTREAM}`);
});

for (const signal of ["SIGINT", "SIGTERM"]) {
    process.on(signal, () => {
        console.log(`[gateway-proxy] ${signal} — closing`);
        server.close(() => process.exit(0));
    });
}
