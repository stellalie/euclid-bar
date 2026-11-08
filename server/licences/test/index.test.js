// node --test server/licences/test
import assert from "node:assert/strict";
import { test, beforeEach } from "node:test";
import worker, { sign } from "../src/index.js";

// Test-only key. Its public half is in Tests/EuclidCoreTests/LicenceTests.swift, which checks
// that a key signed here verifies in the app.
const SEED = "AAECAwQFBgcICQoLDA0ODxAREhMUFRYXGBkaGxwdHh8=";
const TXN = "txn_01m686kb9bbd1pt6exbz6saqs8";
const env = {
  PADDLE_API: "https://api.paddle.com",
  PADDLE_API_KEY: "k",
  LICENCE_PRIVATE_KEY: SEED,
  ALLOWED_ORIGIN: "https://lgtm.ninja",
  PRICES: '{"pri_personal":"personal","pri_business":"business"}',
};

let paddle;
let calls;
beforeEach(() => {
  calls = [];
  paddle = {
    [`/transactions/${TXN}`]: {
      id: TXN,
      status: "completed",
      customer_id: "ctm_1",
      business_id: null,
      billed_at: "2026-10-31T05:30:00Z",
      created_at: "2026-10-31T05:29:00Z",
      items: [{ price: { id: "pri_business" }, quantity: 3 }],
    },
    "/customers/ctm_1": { name: "Ada Lovelace", email: "ada@example.com" },
    "/customers/ctm_1/businesses/biz_1": { name: "Acme Pty Ltd" },
  };
  globalThis.fetch = async (url, init) => {
    calls.push({ url, auth: init.headers.Authorization });
    const data = paddle[new URL(url).pathname];
    return data ? new Response(JSON.stringify({ data })) : new Response("{}", { status: 404 });
  };
});

const get = (txn) => worker.fetch(new Request(`https://licences.lgtm.ninja/v1/licence?txn=${txn}`), env);

async function verify(key) {
  const [payload, signature] = key.slice("EUCLID-".length).split(".");
  const raw = (s) => Uint8Array.from(atob(s.replaceAll("-", "+").replaceAll("_", "/")), (c) => c.charCodeAt(0));
  const pkcs8 = new Uint8Array([0x30, 0x2e, 0x02, 0x01, 0x00, 0x30, 0x05, 0x06, 0x03, 0x2b, 0x65, 0x70, 0x04, 0x22, 0x04, 0x20, ...raw(SEED)]);
  const priv = await crypto.subtle.importKey("pkcs8", pkcs8, { name: "Ed25519" }, true, ["sign"]);
  const jwk = await crypto.subtle.exportKey("jwk", priv);
  const pub = await crypto.subtle.importKey("jwk", { kty: "OKP", crv: "Ed25519", x: jwk.x }, { name: "Ed25519" }, false, ["verify"]);
  assert.ok(await crypto.subtle.verify("Ed25519", pub, raw(signature), new TextEncoder().encode(payload)));
  return JSON.parse(new TextDecoder().decode(raw(payload)));
}

test("a completed Business order gets a signed key for its seats", async () => {
  const res = await get(TXN);
  assert.equal(res.status, 200);
  assert.equal(res.headers.get("Access-Control-Allow-Origin"), "https://lgtm.ninja");
  const body = await res.json();
  assert.deepEqual(await verify(body.key), {
    edition: "business", issued: "2026-10-31", name: "Ada Lovelace", order: TXN, seats: 3,
  });
  assert.ok(calls.every((c) => c.auth === "Bearer k"));
});

test("the same order always gets the same key", async () => {
  const a = await (await get(TXN)).json();
  const b = await (await get(TXN)).json();
  assert.equal(a.key, b.key);
});

test("a business purchase is licensed to the business", async () => {
  paddle[`/transactions/${TXN}`].business_id = "biz_1";
  assert.equal((await verify((await (await get(TXN)).json()).key)).name, "Acme Pty Ltd");
});

test("Personal is always one seat", async () => {
  paddle[`/transactions/${TXN}`].items = [{ price: { id: "pri_personal" }, quantity: 2 }];
  const licence = await verify((await (await get(TXN)).json()).key);
  assert.equal(licence.edition, "personal");
  assert.equal(licence.seats, 1);
});

test("unpaid, unknown and non-Euclid orders get no key", async () => {
  paddle[`/transactions/${TXN}`].status = "ready";
  assert.equal((await get(TXN)).status, 409);
  assert.equal((await get("txn_01m686kb9bbd1pt6exbz6saqs9")).status, 404);
  paddle[`/transactions/${TXN}`].status = "completed";
  paddle[`/transactions/${TXN}`].items = [{ price: { id: "pri_other" }, quantity: 1 }];
  assert.equal((await get(TXN)).status, 404);
});

test("bad ids never reach Paddle", async () => {
  for (const txn of ["", "txn_x", "../customers/ctm_1", `${TXN}%2F..`]) assert.equal((await get(txn)).status, 400);
  assert.equal(calls.length, 0);
});

test("a Paddle outage is a 502, not a key", async () => {
  globalThis.fetch = async () => new Response("down", { status: 500 });
  assert.equal((await get(TXN)).status, 502);
});

test("other paths and methods", async () => {
  assert.equal((await worker.fetch(new Request("https://licences.lgtm.ninja/"), env)).status, 404);
  const post = new Request(`https://licences.lgtm.ninja/v1/licence?txn=${TXN}`, { method: "POST" });
  assert.equal((await worker.fetch(post, env)).status, 405);
});

test("matches the key the Swift test verifies", async () => {
  const licence = { edition: "business", issued: "2026-10-31", name: "Ada Lovelace", order: TXN, seats: 3 };
  assert.equal(await sign(licence, SEED), SWIFT_FIXTURE);
});

// Also in LicenceTests.acceptsKeysFromTheLicenceServer.
const SWIFT_FIXTURE =
  "EUCLID-eyJlZGl0aW9uIjoiYnVzaW5lc3MiLCJpc3N1ZWQiOiIyMDI2LTEwLTMxIiwibmFtZSI6IkFkYSBMb3ZlbGFjZSIsIm9yZGVyIjoidHhuXzAxbTY4NmtiOWJiZDFwdDZleGJ6NnNhcXM4Iiwic2VhdHMiOjN9.MFWkRgdl0xOzQHKv2KEvlJnLhSi6WPRx8ML6L7tdeNPH_-TFn-YV7l-5fRcj-Li9ft2gTux6kWPOWYC0xmv5Dg";
