// Local auth-injection proxy for Azure OpenAI managed-identity auth.
//
// OpenClaw points OPENAI_BASE_URL at this proxy; the proxy attaches a fresh
// Entra ID bearer token to every forwarded request. getBearerTokenProvider
// caches tokens and only refreshes when near expiry, so the SDK gets a valid
// token forever without restarts.
//
// Why a proxy and not env-var refresh?
//   process.env mutations in a parent never propagate to spawned children, and
//   SIGHUP on OpenClaw triggers a config reload but does not re-read env. The
//   only reliable refresh path is at request time.
//
// Optional escape hatch: setting AOAI_DEFAULT_API_VERSION (e.g. when an
// adapter needs the classic `/openai/deployments/...` surface that requires
// `?api-version=...`) makes the proxy append that query value to any
// `/openai/...` request that doesn't already carry one. Off by default —
// today's baseUrl points at the AOAI v1 endpoint which doesn't need it.

import http from "node:http";
import { request as httpsRequest } from "node:https";
import { DefaultAzureCredential, getBearerTokenProvider } from "@azure/identity";

const UPSTREAM = process.env.AOAI_UPSTREAM_URL;
const PORT = Number(process.env.AUTH_PROXY_PORT || 18790);
const SCOPE = "https://cognitiveservices.azure.com/.default";
const DEFAULT_API_VERSION = (process.env.AOAI_DEFAULT_API_VERSION || "").trim();

if (!UPSTREAM) {
  console.error("[auth-proxy] AOAI_UPSTREAM_URL is required (e.g. https://<name>.openai.azure.com)");
  process.exit(2);
}

const upstream = new URL(UPSTREAM);
const credential = new DefaultAzureCredential();
const tokenProvider = getBearerTokenProvider(credential, SCOPE);

function ensureApiVersion(requestUrl) {
  if (!DEFAULT_API_VERSION) return requestUrl;
  if (!requestUrl || !requestUrl.startsWith("/openai/")) return requestUrl;
  const qIndex = requestUrl.indexOf("?");
  const query = qIndex === -1 ? "" : requestUrl.slice(qIndex + 1);
  if (/(^|&)api-version=/.test(query)) return requestUrl;
  const sep = qIndex === -1 ? "?" : "&";
  return `${requestUrl}${sep}api-version=${encodeURIComponent(DEFAULT_API_VERSION)}`;
}

const server = http.createServer(async (req, res) => {
  let token;
  try {
    token = await tokenProvider();
  } catch (err) {
    console.error("[auth-proxy] token-fetch failed:", err.message);
    res.writeHead(502, { "content-type": "text/plain" });
    res.end("auth-proxy: token-fetch-failed");
    return;
  }

  const headers = { ...req.headers };
  delete headers.host;
  delete headers["api-key"];
  headers.authorization = `Bearer ${token}`;
  headers.host = upstream.host;

  const forwardPath = ensureApiVersion(req.url);

  const upReq = httpsRequest(
    {
      hostname: upstream.hostname,
      port: upstream.port || 443,
      method: req.method,
      path: forwardPath,
      headers,
    },
    (upRes) => {
      res.writeHead(upRes.statusCode ?? 502, upRes.headers);
      upRes.pipe(res);
    },
  );

  upReq.on("error", (err) => {
    console.error("[auth-proxy] upstream error:", err.message);
    if (!res.headersSent) {
      res.writeHead(502, { "content-type": "text/plain" });
    }
    res.end("auth-proxy: upstream-error");
  });

  req.pipe(upReq);
});

server.listen(PORT, "127.0.0.1", () => {
  console.log(`[auth-proxy] listening on 127.0.0.1:${PORT} -> ${UPSTREAM}`);
});

for (const sig of ["SIGTERM", "SIGINT"]) {
  process.on(sig, () => {
    server.close(() => process.exit(0));
  });
}
