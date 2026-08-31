// dsv4-registry — a pull-only OCI/Docker registry served from Cloudflare R2.
//
// Why this exists: pulling the 185 GB all-in-one image from GHCR fails on
// RunPod. GHCR throttles its *blob* endpoint with an instantaneous token
// bucket (sub-second `retry-after`), so a fast parallel puller draws a steady
// ~20% of `TOOMANYREQUESTS` — reproduced identically from a clean home IP and a
// datacenter IP, authenticated or not. RunPod's puller treats one blob 429 as
// fatal and restarts the whole pull, so it never converges.
//
// This Worker removes GHCR from the pull path entirely: manifests + blobs live
// in R2 (free egress, no GHCR-style blob throttle) and are served straight from
// the R2 binding. Pull-only and public — no token is needed to pull, and no
// credential is stored at the edge.
//
// R2 layout:
//   blobs/sha256:<hex>            raw blob bytes (config + every layer)
//   manifests/<name>/<reference>  raw manifest bytes (stored under tag AND digest)

// Only this repository is served — the registry is not a general-purpose open
// registry, it hosts exactly one image. Anything else 404s.
const ALLOWED_REPO = "dsv4-flash-b300";

function err(status, code, message) {
  return new Response(JSON.stringify({ errors: [{ code, message }] }), {
    status,
    headers: { "Content-Type": "application/json" },
  });
}

async function sha256hex(buf) {
  const h = await crypto.subtle.digest("SHA-256", buf);
  return [...new Uint8Array(h)].map((b) => b.toString(16).padStart(2, "0")).join("");
}

function manifestType(bytes) {
  try {
    const o = JSON.parse(new TextDecoder().decode(bytes));
    return o.mediaType || "application/vnd.oci.image.manifest.v1+json";
  } catch {
    return "application/vnd.oci.image.manifest.v1+json";
  }
}

export default {
  async fetch(request, env) {
    const url = new URL(request.url);
    const path = url.pathname;
    const method = request.method;

    // Registry v2 API probe — a 200 here tells the client "no auth needed".
    if (path === "/v2" || path === "/v2/") {
      return new Response("{}", {
        status: 200,
        headers: {
          "Content-Type": "application/json",
          "Docker-Distribution-Api-Version": "registry/2.0",
        },
      });
    }

    // A tiny landing page for humans hitting the root.
    if (path === "/" || path === "") {
      return new Response(
        "dsv4-registry — pull-only OCI registry on Cloudflare R2.\n" +
          "Pull: docker pull " + url.host + "/dsv4-flash-b300:2.0.0\n",
        { status: 200, headers: { "Content-Type": "text/plain; charset=utf-8" } }
      );
    }

    const m = path.match(/^\/v2\/(.+)\/(manifests|blobs)\/(.+)$/);
    if (!m) return err(404, "NOT_FOUND", "not a registry path");
    const name = m[1];
    const kind = m[2];
    const ref = decodeURIComponent(m[3]);

    // Pull-only, and only for the one image this registry hosts.
    if (method !== "GET" && method !== "HEAD") {
      return err(405, "UNSUPPORTED", "this registry is pull-only");
    }
    if (name !== ALLOWED_REPO) {
      return err(404, "NAME_UNKNOWN", "unknown repository");
    }

    // ---- manifests ----
    if (kind === "manifests") {
      const obj = await env.BUCKET.get(`manifests/${name}/${ref}`);
      if (!obj) return err(404, "MANIFEST_UNKNOWN", "manifest unknown");
      const bytes = await obj.arrayBuffer();
      const digest = "sha256:" + (await sha256hex(bytes));
      const headers = {
        "Content-Type": manifestType(bytes),
        "Docker-Content-Digest": digest,
        "Content-Length": String(bytes.byteLength),
        "Cache-Control": "public, max-age=3600",
      };
      if (method === "HEAD") return new Response(null, { status: 200, headers });
      return new Response(bytes, { status: 200, headers });
    }

    // ---- blobs ----  ref is "sha256:<hex>"
    const key = `blobs/${ref}`;

    if (method === "HEAD") {
      const head = await env.BUCKET.head(key);
      if (!head) return err(404, "BLOB_UNKNOWN", "blob unknown");
      return new Response(null, {
        status: 200,
        headers: {
          "Content-Length": String(head.size),
          "Content-Type": "application/octet-stream",
          "Docker-Content-Digest": ref,
          "Accept-Ranges": "bytes",
        },
      });
    }

    // GET, with Range support (containerd/RunPod issue ranged blob requests).
    const rangeHeader = request.headers.get("Range");
    if (rangeHeader) {
      const head = await env.BUCKET.head(key);
      if (!head) return err(404, "BLOB_UNKNOWN", "blob unknown");
      const total = head.size;
      const mm = rangeHeader.match(/bytes=(\d*)-(\d*)/);
      if (mm) {
        let start = mm[1] === "" ? null : parseInt(mm[1], 10);
        let end = mm[2] === "" ? null : parseInt(mm[2], 10);
        if (start === null) {
          // suffix range: bytes=-N
          start = Math.max(0, total - end);
          end = total - 1;
        } else if (end === null || end >= total) {
          end = total - 1;
        }
        const length = end - start + 1;
        const obj = await env.BUCKET.get(key, { range: { offset: start, length } });
        if (!obj) return err(404, "BLOB_UNKNOWN", "blob unknown");
        return new Response(obj.body, {
          status: 206,
          headers: {
            "Content-Type": "application/octet-stream",
            "Docker-Content-Digest": ref,
            "Accept-Ranges": "bytes",
            "Content-Range": `bytes ${start}-${end}/${total}`,
            "Content-Length": String(length),
          },
        });
      }
    }

    const obj = await env.BUCKET.get(key);
    if (!obj) return err(404, "BLOB_UNKNOWN", "blob unknown");
    return new Response(obj.body, {
      status: 200,
      headers: {
        "Content-Type": "application/octet-stream",
        "Docker-Content-Digest": ref,
        "Accept-Ranges": "bytes",
        "Content-Length": String(obj.size),
        // blobs are content-addressed, so they never change
        "Cache-Control": "public, max-age=31536000, immutable",
      },
    });
  },
};
