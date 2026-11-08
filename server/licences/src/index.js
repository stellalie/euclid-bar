// Hands out the licence key for a completed Paddle purchase. The thank-you page at
// lgtm.ninja/euclid/thanks/ calls GET /v1/licence?txn=txn_… right after checkout.
// Nothing is stored: the key is rebuilt from the Paddle transaction on every call, and
// Ed25519 is deterministic, so the same purchase always gets the same key.
// Same key format as Sources/EuclidCore/Licence/Licence.swift.

const TXN = /^txn_[0-9a-z]{26}$/;

export default {
  async fetch(request, env) {
    const url = new URL(request.url);
    const cors = {
      "Access-Control-Allow-Origin": env.ALLOWED_ORIGIN,
      "Access-Control-Allow-Methods": "GET",
      Vary: "Origin",
    };
    if (url.pathname !== "/v1/licence") return json({ error: "Not found" }, 404, cors);
    if (request.method === "OPTIONS") return new Response(null, { status: 204, headers: cors });
    if (request.method !== "GET") return json({ error: "GET a licence" }, 405, cors);

    if (env.LIMITER) {
      const { success } = await env.LIMITER.limit({ key: request.headers.get("cf-connecting-ip") ?? "?" });
      if (!success) return json({ error: "Too many requests. Try again in a minute." }, 429, cors);
    }

    const txn = url.searchParams.get("txn") ?? "";
    if (!TXN.test(txn)) return json({ error: "That isn't a Paddle order id (txn_…)." }, 400, cors);

    try {
      const result = await licenceFor(txn, env);
      return json(result.error ? result : { key: result.key, licence: result.licence }, result.status ?? 200, cors);
    } catch (e) {
      console.error(e);
      return json({ error: "Couldn't reach Paddle. Try again, or email hello@lgtm.ninja." }, 502, cors);
    }
  },
};

/** The licence for one Paddle transaction, or `{ error, status }`. */
export async function licenceFor(txn, env) {
  const t = await paddle(`/transactions/${txn}`, env);
  if (!t) return { error: "No order with that id.", status: 404 };
  // `paid` comes a moment before `completed`; both mean the money (or a 100% discount) went through.
  if (t.status !== "completed" && t.status !== "paid") {
    return { error: "That order isn't paid yet. Refresh in a few seconds.", status: 409 };
  }

  const prices = JSON.parse(env.PRICES);
  const line = t.items.find((i) => prices[i.price?.id ?? i.price_id]);
  if (!line) return { error: "That order isn't for Euclid.", status: 404 };
  const edition = prices[line.price?.id ?? line.price_id];

  const customer = t.customer_id ? await paddle(`/customers/${t.customer_id}`, env) : null;
  const business = t.business_id && t.customer_id
    ? await paddle(`/customers/${t.customer_id}/businesses/${t.business_id}`, env)
    : null;
  const name = business?.name || customer?.name || customer?.email || "Euclid user";

  const licence = {
    edition,
    issued: (t.billed_at ?? t.created_at).slice(0, 10),
    name,
    order: txn,
    seats: edition === "business" ? line.quantity : 1,
  };
  return { key: await sign(licence, env.LICENCE_PRIVATE_KEY), licence };
}

async function paddle(path, env) {
  const res = await fetch(env.PADDLE_API + path, {
    headers: { Authorization: `Bearer ${env.PADDLE_API_KEY}`, "Paddle-Version": "1" },
  });
  if (res.status === 404) return null;
  if (!res.ok) throw new Error(`Paddle ${path}: ${res.status} ${await res.text()}`);
  return (await res.json()).data;
}

/** `EUCLID-<payload>.<signature>`: base64url JSON, Ed25519 over the payload's base64url text. */
export async function sign(licence, privateKeyBase64) {
  const keys = Object.keys(licence).sort();
  const payload = b64url(new TextEncoder().encode(JSON.stringify(licence, keys)));
  // CryptoKit's raw private key is the 32-byte seed; WebCrypto takes it wrapped as PKCS#8.
  const seed = Uint8Array.from(atob(privateKeyBase64), (c) => c.charCodeAt(0));
  if (seed.length !== 32) throw new Error("LICENCE_PRIVATE_KEY must be 32 bytes, base64");
  const pkcs8 = new Uint8Array([...PKCS8_ED25519_PREFIX, ...seed]);
  const key = await crypto.subtle.importKey("pkcs8", pkcs8, { name: "Ed25519" }, false, ["sign"]);
  const signature = await crypto.subtle.sign("Ed25519", key, new TextEncoder().encode(payload));
  return `EUCLID-${payload}.${b64url(new Uint8Array(signature))}`;
}

const PKCS8_ED25519_PREFIX = [0x30, 0x2e, 0x02, 0x01, 0x00, 0x30, 0x05, 0x06, 0x03, 0x2b, 0x65, 0x70, 0x04, 0x22, 0x04, 0x20];

function b64url(bytes) {
  return btoa(String.fromCharCode(...bytes)).replaceAll("+", "-").replaceAll("/", "_").replaceAll("=", "");
}

function json(body, status, headers) {
  return new Response(JSON.stringify(body), { status, headers: { ...headers, "Content-Type": "application/json" } });
}
