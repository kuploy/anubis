#!/usr/bin/env node
/**
 * Serve the built SPA, and proxy /api to the backend.
 *
 * WHY THIS EXISTS INSTEAD OF `serve -s build`.
 *
 * The React app calls its API on its own origin. In development that works
 * because `package.json`'s `"proxy": "http://localhost:5000/"` is handled by
 * CRA's dev server — which is not running in a production image.
 *
 * So in a container the app's `/api/...` calls hit the static server. And
 * `serve -s` is SPA mode: ANY unmatched path returns `index.html` with HTTP
 * 200. The request does not fail. `fetch` resolves, `.json()` throws on HTML,
 * and the UI shows an unexpected-error state while every health signal reads
 * green — pod ready, ingress up, `/` returns 200. A deployment that looks
 * correct from the outside and cannot talk to its backend.
 *
 * This keeps the SPA fallback for page routes and sends `/api` where it
 * belongs. Node builtins only: the runtime stage deletes node_modules, so
 * `http-proxy-middleware` (a dependency of the BUILD stage) is not available
 * here, and adding a runtime dependency tree to serve a static directory is a
 * poor trade.
 *
 * A FAILING API MUST NOT LOOK LIKE A PAGE. If the backend is unreachable this
 * answers 502 with JSON, never index.html — the whole defect above is a
 * backend error wearing a 200.
 */
import { createServer, request as httpRequest } from "node:http";
import { createReadStream, promises as fs } from "node:fs";
import { extname, join, normalize } from "node:path";

const ROOT = join(process.cwd(), "build");
const PORT = Number(process.env.PORT || 3000);
/** Same namespace, so Kubernetes DNS resolves the service name directly. */
const TARGET = new URL(process.env.API_PROXY_TARGET || "http://anubis-api:5000");
/**
 * REFUSE AT STARTUP, not per request. `node:http` cannot speak TLS, so an
 * `https://` target would have been proxied to port 80 in cleartext — a
 * silent downgrade that looks like it works until something inspects the
 * wire. Dying here is the honest failure: the pod will not start and the
 * reason is the first line of its log.
 */
if (TARGET.protocol !== "http:") {
  console.error(`[web] API_PROXY_TARGET must be http://; got ${TARGET.protocol}//. This proxy cannot do TLS.`);
  process.exit(1);
}
const TARGET_PORT = Number(TARGET.port || 80);
/** A backend that accepts and never answers must not hold a socket forever. */
const UPSTREAM_TIMEOUT_MS = Number(process.env.API_PROXY_TIMEOUT_MS || 30_000);
/** Prefixes the backend owns. Everything else is the SPA's. */
const API_PREFIXES = (process.env.API_PROXY_PREFIXES || "/api,/ws,/public")
  .split(",").map((s) => s.trim()).filter(Boolean);

/*
 * STRIP `/api` BEFORE FORWARDING, because the API does not serve it.
 *
 * The SPA calls `/api/public/auth/whoami`. The Flask app registers
 * `/public/auth/whoami` — there is no `/api` prefix anywhere in its url_map
 * (171 routes, checked against the running container). Upstream's deployment
 * reconciles the two at the edge, not in the app: k8s/chart/templates/
 * ingress.yml:1-11 declares a Traefik StripPrefix middleware named
 * `strip-api`, and the route matching PathPrefix(`/api/`) applies it before
 * handing off to the api service (:69-73).
 *
 * This proxy replaces that edge, so it has to do the same strip. Forwarding
 * verbatim gives a 404 from the API for every call the SPA makes — which is
 * a working proxy, a reachable backend, and a UI that still does nothing.
 *
 * Only `/api` is stripped, matching upstream's middleware exactly. `/ws` and
 * `/public` are paths the API really serves, so they pass through untouched.
 */
const STRIP_PREFIXES = (process.env.API_PROXY_STRIP_PREFIXES || "/api")
  .split(",").map((s) => s.trim()).filter(Boolean);

/** `/api/public/x` -> `/public/x`; a bare `/api` -> `/`. */
export const upstreamPath = (url) => {
  for (const p of STRIP_PREFIXES) {
    if (url === p) return "/";
    if (url.startsWith(`${p}/`)) return url.slice(p.length);
    if (url.startsWith(`${p}?`)) return `/${url.slice(p.length)}`;
  }
  return url;
};

const TYPES = {
  ".html": "text/html; charset=utf-8", ".js": "text/javascript; charset=utf-8",
  ".css": "text/css; charset=utf-8", ".json": "application/json; charset=utf-8",
  ".svg": "image/svg+xml", ".png": "image/png", ".jpg": "image/jpeg",
  ".ico": "image/x-icon", ".woff": "font/woff", ".woff2": "font/woff2",
  ".map": "application/json; charset=utf-8", ".txt": "text/plain; charset=utf-8",
};

const isApi = (p) => API_PREFIXES.some((x) => p === x || p.startsWith(`${x}/`));

function proxy(req, res) {
  const path = upstreamPath(req.url);
  const upstream = httpRequest(
    { hostname: TARGET.hostname, port: TARGET_PORT, path,
      method: req.method, headers: { ...req.headers, host: TARGET.host } },
    (up) => { res.writeHead(up.statusCode || 502, up.headers); up.pipe(res); },
  );
  upstream.on("error", (err) => {
    // JSON, not index.html. A caller must be able to tell "the API is down"
    // from "here is a web page", which is the bug this file fixes.
    console.error(`[web] proxy to ${TARGET.origin}${path} failed: ${err.message}`);
    if (!res.headersSent) res.writeHead(502, { "content-type": "application/json" });
    res.end(JSON.stringify({ error: "api_unreachable", target: TARGET.origin }));
  });
  upstream.setTimeout(UPSTREAM_TIMEOUT_MS, () => {
    upstream.destroy(new Error(`no response in ${UPSTREAM_TIMEOUT_MS}ms`));
  });
  req.pipe(upstream);
}

async function sendFile(res, file, code = 200) {
  const body = await fs.stat(file);
  res.writeHead(code, {
    "content-type": TYPES[extname(file)] || "application/octet-stream",
    "content-length": body.size,
  });
  createReadStream(file).pipe(res);
}

createServer(async (req, res) => {
  /**
   * DECODE INSIDE THE TRY. `decodeURIComponent("%")` throws URIError, and in
   * an async handler that becomes an unhandled rejection — which Node turns
   * into an uncaught exception and the process EXITS. `GET /%` stopped the
   * container; tini is PID 1 so Kubernetes restarts it, and a client
   * repeating it holds the pod in CrashLoopBackOff. On a template whose whole
   * purpose is being publicly addressable, a scanner finds that by accident.
   *
   * 400 with JSON, for the same reason the proxy answers 502 with JSON: a
   * malformed request is not a page. Found in review of #4.
   */
  let path;
  try {
    path = decodeURIComponent((req.url || "/").split("?")[0]);
  } catch {
    res.writeHead(400, { "content-type": "application/json" });
    res.end(JSON.stringify({ error: "malformed_uri" }));
    return;
  }
  if (isApi(path)) return proxy(req, res);

  // normalize() then confine to ROOT: `/../etc/passwd` must not escape.
  const target = join(ROOT, normalize(path).replace(/^(\.\.[/\\])+/, ""));
  if (!target.startsWith(ROOT)) { res.writeHead(403).end(); return; }

  try {
    const s = await fs.stat(target);
    if (s.isFile()) return await sendFile(res, target);
  } catch { /* fall through to the SPA entry point */ }

  try {
    await sendFile(res, join(ROOT, "index.html"));
  } catch {
    res.writeHead(500, { "content-type": "text/plain" }).end("build/index.html missing");
  }
}).listen(PORT, () => {
  console.log(`[web] serving ${ROOT} on :${PORT}, ${API_PREFIXES.join(",")} -> ${TARGET.origin}`);
});
