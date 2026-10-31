// node --test server/reports/test
import assert from "node:assert/strict";
import { test, beforeEach } from "node:test";
import worker, { issueTitle, validate } from "../src/reports.js";

const report = {
  kind: "crash",
  title: "EXC_BREAKPOINT (SIGTRAP)",
  message: "Fatal error: Index out of range ``` @stellalie #1",
  frames: ["libswiftCore.dylib  _assertionFailure + 172", "euclid-bar  LauncherViewController.reload(_:) + 120"],
  app: "1.2.1",
  build: "121",
  channel: "dev",
  os: "macOS 15.1 (24B83)",
  arch: "arm64",
  fingerprint: "0123456789ab",
};
const env = { GITHUB_REPO: "stellalie/euclid-bar", GITHUB_TOKEN: "t" };

let calls;
let searchItems;
beforeEach(() => {
  calls = [];
  searchItems = [];
  globalThis.fetch = async (url, init) => {
    calls.push({ url, method: init.method, body: init.body && JSON.parse(init.body) });
    const json = url.includes("/search/") ? { items: searchItems } : { number: 42 };
    return new Response(JSON.stringify(json), { status: 200 });
  };
});

const post = (body, e = env) =>
  worker.fetch(new Request("https://reports.lgtm.ninja/v1/report", { method: "POST", body: JSON.stringify(body) }), e);

test("a new bug opens an issue, with sent text fenced", async () => {
  const res = await post(report);
  assert.equal(res.status, 202);
  assert.equal(await res.text(), "#42");
  assert.match(decodeURIComponent(calls[0].url), /repo:stellalie\/euclid-bar is:issue label:crash-report 0123456789ab in:body/);
  const created = calls[1];
  assert.equal(created.url, "https://api.github.com/repos/stellalie/euclid-bar/issues");
  assert.equal(created.body.title, "crash: EXC_BREAKPOINT (SIGTRAP) in LauncherViewController.reload(_:)");
  assert.deepEqual(created.body.labels, ["crash-report"]);
  assert.match(created.body.body, /```text\nFatal error: Index out of range ''' @stellalie #1\n```/);
  assert.match(created.body.body, /Fingerprint: `0123456789ab`/);
});

test("a repeat comments on the open issue", async () => {
  searchItems = [{ number: 7, state: "open", comments: 3 }];
  const res = await post(report);
  assert.equal(await res.text(), "#7");
  assert.equal(calls[1].url, "https://api.github.com/repos/stellalie/euclid-bar/issues/7/comments");
  assert.match(calls[1].body.body, /^Again in Euclid 1\.2\.1 \(121, dev\)/);
});

test("enough repeats stop commenting", async () => {
  searchItems = [{ number: 7, state: "open", comments: 50 }];
  await post(report);
  assert.equal(calls.length, 1);
});

test("a closed bug coming back opens a new issue that points at the old one", async () => {
  searchItems = [{ number: 3, state: "closed", comments: 0 }];
  await post(report);
  assert.match(calls[1].body.body, /Seen before in #3 \(closed\)/);
});

test("rejects anything that isn't a report", async () => {
  assert.equal((await post({ ...report, extra: 1 })).status, 400);
  assert.equal((await post({ ...report, kind: "spam" })).status, 400);
  assert.equal((await post({ ...report, app: "1.2 <b>" })).status, 400);
  assert.equal((await post({ ...report, frames: Array(61).fill("x") })).status, 400);
  assert.equal((await post({ ...report, message: "x".repeat(70_000) })).status, 413);
  const get = await worker.fetch(new Request("https://reports.lgtm.ninja/v1/report"), env);
  assert.equal(get.status, 405);
  assert.equal(calls.length, 0);
});

test("rate limited per address", async () => {
  const res = await post(report, { ...env, LIMITER: { limit: async () => ({ success: false }) } });
  assert.equal(res.status, 429);
  assert.equal(calls.length, 0);
});

test("GitHub failing is a 502, so the app logs it", async () => {
  globalThis.fetch = async () => new Response("nope", { status: 401 });
  assert.equal((await post(report)).status, 502);
});

test("error titles carry the message", () => {
  const e = validate({ ...report, kind: "error", title: "clipboard", message: "history store unavailable: disk full", frames: [] });
  assert.equal(issueTitle(e), "error: clipboard: history store unavailable: disk full");
});
