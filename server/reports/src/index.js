// Receives Euclid's opt-in crash and error reports (`[privacy] crash_reports = true`)
// and files each bug as one issue labelled `crash-report` in the private repo.
// Repeats of the same bug (same fingerprint) become a comment on its open issue.
// Nothing is stored here: no IPs, no logs beyond Cloudflare's defaults.

export const LABEL = "crash-report";
const MAX_BODY = 64_000;
const MAX_REPEAT_COMMENTS = 50;

export default {
  async fetch(request, env) {
    const url = new URL(request.url);
    if (url.pathname !== "/v1/report") return text("Not found", 404);
    if (request.method !== "POST") return text("POST a report", 405);

    if (env.LIMITER) {
      const { success } = await env.LIMITER.limit({ key: request.headers.get("cf-connecting-ip") ?? "?" });
      if (!success) return text("Too many reports", 429);
    }

    const raw = await request.text();
    if (raw.length > MAX_BODY) return text("Report too large", 413);
    let report;
    try {
      report = validate(JSON.parse(raw));
    } catch (e) {
      return text(`Bad report: ${e.message}`, 400);
    }

    try {
      const result = await file(report, env);
      return text(result, 202);
    } catch (e) {
      console.error(e);
      return text("Couldn't file the report", 502);
    }
  },
};

/** The app's `CrashReport`, checked field by field. Throws on anything else. */
export function validate(r) {
  const keys = ["kind", "title", "message", "frames", "app", "build", "channel", "os", "arch", "fingerprint"];
  if (typeof r !== "object" || r === null || Array.isArray(r)) throw new Error("not an object");
  for (const k of Object.keys(r)) if (!keys.includes(k)) throw new Error(`unknown field ${k}`);
  if (r.kind !== "crash" && r.kind !== "error") throw new Error("kind");
  if (!/^[0-9a-f]{12}$/.test(r.fingerprint)) throw new Error("fingerprint");
  const str = (k, max) => {
    if (typeof r[k] !== "string" || r[k].length > max) throw new Error(k);
  };
  str("title", 210);
  str("message", 1010);
  for (const k of ["app", "build", "channel", "os", "arch"]) {
    str(k, 60);
    if (!/^[\w .()\-]*$/.test(r[k])) throw new Error(k);
  }
  if (!Array.isArray(r.frames) || r.frames.length > 60) throw new Error("frames");
  for (const f of r.frames) if (typeof f !== "string" || f.length > 410) throw new Error("frames");
  return r;
}

/** Comment on the bug's open issue, or open one. Returns what it did. */
export async function file(report, env) {
  const gh = github(env);
  const q = `repo:${env.GITHUB_REPO} is:issue label:${LABEL} ${report.fingerprint} in:body`;
  const found = await gh("GET", `/search/issues?q=${encodeURIComponent(q)}&per_page=10`);
  const open = found.items.find((i) => i.state === "open");
  if (open) {
    if (open.comments >= MAX_REPEAT_COMMENTS) return `#${open.number} (enough repeats)`;
    await gh("POST", `/repos/${env.GITHUB_REPO}/issues/${open.number}/comments`, { body: repeatComment(report) });
    return `#${open.number}`;
  }
  const closed = found.items.find((i) => i.state === "closed");
  const issue = await gh("POST", `/repos/${env.GITHUB_REPO}/issues`, {
    title: issueTitle(report),
    body: issueBody(report, closed?.number),
    labels: [LABEL],
  });
  return `#${issue.number}`;
}

/** "crash: EXC_BREAKPOINT (SIGTRAP) in LauncherViewController.reload(_:)" */
export function issueTitle(r) {
  let title;
  if (r.kind === "crash") {
    const own = r.frames.find((f) => f.startsWith("euclid-bar "));
    const where = own?.replace(/^euclid-bar\s+/, "").replace(/\s*\+\s*(0x)?[0-9a-f]+$/i, "");
    title = `crash: ${r.title}${where ? ` in ${where}` : ""}`;
  } else {
    title = `error: ${r.title}: ${r.message}`;
  }
  title = title.replace(/\s+/g, " ");
  return title.length > 120 ? `${title.slice(0, 119)}…` : title;
}

export function issueBody(r, previous) {
  return [
    `**${r.kind}** in Euclid ${r.app} (${r.build}, ${r.channel}) · ${r.os} · ${r.arch}`,
    "",
    `Fingerprint: \`${r.fingerprint}\``,
    previous ? `\nSeen before in #${previous} (closed): the fix may not cover this, or it came back.` : "",
    "",
    block(r.message || "(no message)"),
    r.frames.length ? `\nStack (crashed thread, top first):\n\n${block(r.frames.join("\n"))}` : "",
    "",
    "_Sent by Euclid's opt-in crash reporter. The daily fix routine picks this up._",
  ].join("\n");
}

export function repeatComment(r) {
  return `Again in Euclid ${r.app} (${r.build}, ${r.channel}) · ${r.os} · ${r.arch}` +
    (r.kind === "error" ? `\n\n${block(r.message)}` : "");
}

/** Sent text only ever lands inside a fence, so it can't mention people, link issues or add markup. */
function block(s) {
  return "```text\n" + s.replace(/`/g, "'") + "\n```";
}

function github(env) {
  return async (method, path, body) => {
    const res = await fetch(`https://api.github.com${path}`, {
      method,
      headers: {
        Authorization: `Bearer ${env.GITHUB_TOKEN}`,
        Accept: "application/vnd.github+json",
        "X-GitHub-Api-Version": "2022-11-28",
        "User-Agent": "euclid-reports",
        ...(body ? { "Content-Type": "application/json" } : {}),
      },
      body: body ? JSON.stringify(body) : undefined,
    });
    if (!res.ok) throw new Error(`GitHub ${method} ${path.split("?")[0]}: ${res.status} ${await res.text()}`);
    return res.json();
  };
}

function text(body, status) {
  return new Response(body, { status, headers: { "Content-Type": "text/plain" } });
}
