import Foundation

/// The plugin guide Euclid keeps at `<config>/plugins/AGENTS.md`, written for people and
/// for coding agents ("make me a plugin that…"), plus the example plugins `--plugin add` installs.
public enum PluginGuide {
    static let marker = "<!-- Written by Euclid; it's replaced on update. Put your own notes in another file. -->"

    /// Write `AGENTS.md` into the plugins folder unless you replaced it with your own.
    public static func install(in pluginsDirectory: URL) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: pluginsDirectory, withIntermediateDirectories: true)
        let url = pluginsDirectory.appendingPathComponent("AGENTS.md")
        if let existing = try? String(contentsOf: url, encoding: .utf8) {
            guard existing.hasPrefix(marker), existing != guide else { return } // yours, or current
        }
        try guide.write(to: url, atomically: true, encoding: .utf8)
    }

    /// An example plugin's files, by name: `euclid-bar --plugin add github`.
    public static let examples: [String: [(name: String, text: String, executable: Bool)]] = [
        "github": [("plugin.toml", githubManifest, false), ("items.sh", githubScript, true), ("search.sh", githubSearch, true)],
        "linear": [("plugin.toml", linearManifest, false), ("items.sh", linearScript, true)],
        "bitbucket": [("plugin.toml", bitbucketManifest, false), ("items.sh", bitbucketScript, true)],
        "jira": [("plugin.toml", jiraManifest, false), ("items.sh", jiraItems, true), ("open.sh", jiraOpen, true),
                 ("branch.sh", jiraBranch, true)],
        "slack": [("plugin.toml", slackManifest, false), ("channels.sh", slackChannels, true), ("search.sh", slackSearch, true)],
        "tokens": [("plugin.toml", tokensManifest, false), ("today.sh", tokensScript, true)],
        "define": [("plugin.toml", defineManifest, false), ("define.js", defineScript, false)],
        "currency": [("plugin.toml", currencyManifest, false), ("convert.sh", currencyScript, true)],
        "contacts": [("plugin.toml", contactsManifest, false), ("people.js", contactsScript, false)],
        "shortcuts": [("plugin.toml", shortcutsManifest, false), ("list.sh", shortcutsScript, true)],
        "cleanlinks": [("plugin.toml", cleanlinksManifest, false), ("clean.sh", cleanlinksScript, true)],
        "reveal": [("plugin.toml", revealManifest, false)],
        "ai": [("plugin.toml", aiManifest, false), ("ai.sh", aiScript, true), ("continue.sh", aiContinue, true)],
        "raycast": [("plugin.toml", raycastManifest, false), ("list.sh", raycastList, true), ("scan.awk", raycastScan, false),
                    ("run.sh", raycastRun, true)],
        "emoji": [("plugin.toml", emojiManifest, false), ("items.sh", emojiItems, true), ("grid.sh", emojiGrid, true),
                  ("find.sh", emojiFind, true), ("emoji.tsv", emojiData + "\n", false)],
        "volume": [("plugin.toml", volumeManifest, false), ("items.sh", volumeItems, true), ("find.sh", volumeFind, true),
                   ("set.sh", volumeSet, true)],
        "kill-process": [("plugin.toml", killManifest, false), ("items.sh", killItems, true), ("list.sh", killList, true),
                         ("kill.sh", killKill, true)],
        "docker": [("plugin.toml", dockerManifest, false), ("items.sh", dockerItems, true), ("containers.sh", dockerContainers, true),
                   ("container.sh", dockerContainer, true), ("logs.sh", dockerLogs, true), ("act.sh", dockerAct, true),
                   ("shell.sh", dockerShell, true)],
    ]

    /// Write an example into `<plugins>/<name>`. Fails if that folder already exists.
    public static func installExample(_ name: String, in pluginsDirectory: URL) throws -> URL {
        guard let files = examples[name] else {
            throw PluginRunner.Failure("no example plugin named '\(name)' (try: \(examples.keys.sorted().joined(separator: ", ")))")
        }
        let folder = pluginsDirectory.appendingPathComponent(name)
        let fm = FileManager.default
        guard !fm.fileExists(atPath: folder.path) else { throw PluginRunner.Failure("\(folder.path) already exists") }
        try fm.createDirectory(at: folder, withIntermediateDirectories: true)
        for file in files {
            let url = folder.appendingPathComponent(file.name)
            try file.text.write(to: url, atomically: true, encoding: .utf8)
            if file.executable { try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path) }
        }
        return folder
    }

    static let githubManifest = #"""
name = "GitHub"
description = "Your open PRs, PRs waiting on your review, and issues assigned to you. Uses the GitHub CLI: brew install gh && gh auth login"

[source]
run = "./items.sh"
refresh_minutes = 5

[answer]                  # `gh fix login`: issues and PRs as you type, right in the bar
run    = './search.sh rows "$1"'
prefix = "gh"

[[action]]
name = "Search GitHub code"
run  = 'open "https://github.com/search?type=code&q=$EUCLID_QUERY_URL"'

[settings]
limit = 30          # per list; override in config.toml with [plugin.github] limit = 50
"""#

    static let githubScript = #"""
#!/bin/sh
# Prints one JSON object per line for Euclid. `gh` does the auth and the JSON (--jq).
set -eu
command -v gh >/dev/null 2>&1 || { echo "needs the GitHub CLI: brew install gh && gh auth login" >&2; exit 1; }
limit=${EUCLID_SETTING_LIMIT:-30}
echo '{"title":"Search GitHub","subtitle":"Issues and PRs, as you type","run":"./search.sh open","icon":"magnifyingglass","id":"github:search"}'
# ⌘K on a row: copy its URL, approve it, or comment (asks for the text first).
row='{title, subtitle: "\(.repository.nameWithOwner) · #\(.number)", open: .url, id: .url, icon: "arrow.triangle.pull",
  actions: [{title: "Copy URL", copy: .url, icon: "link"},
            {title: "Approve", run: "./search.sh approve \(.url | @sh)", icon: "checkmark.circle"},
            {title: "Comment…", run: "./search.sh comment \(.url | @sh)", icon: "text.bubble",
             arguments: [{placeholder: "Comment"}]}]}'

gh search prs --review-requested=@me --state=open --limit "$limit" --json number,title,url,repository \
  --jq ".[] | $row + {label: \"Review\", suggest: true} | tojson"
gh search prs --author=@me --state=open --limit "$limit" --json number,title,url,repository \
  --jq ".[] | $row + {label: \"Your PR\"} | tojson"
gh search issues --assignee=@me --state=open --limit "$limit" --json number,title,url,repository \
  --jq ".[] | $row + {label: \"Issue\", icon: \"smallcircle.filled.circle\"} | tojson"
"""#

    static let githubSearch = #"""
#!/bin/sh
# ./search.sh open [words]   a view that searches your issues and PRs as you type (Euclid reruns
#                            `./search.sh rows <what you typed>` after each pause)
# ./search.sh approve <url>  approve a PR      ./search.sh comment <url> <text>  comment on it
set -eu
command -v gh >/dev/null 2>&1 || { echo "needs the GitHub CLI: brew install gh && gh auth login" >&2; exit 1; }
what=${1:-open}
case $what in
  approve) gh pr review "$2" --approve >/dev/null; echo '{"notice":"Approved"}'; exit 0 ;;
  comment) gh issue comment "$2" --body "$3" >/dev/null; echo '{"notice":"Commented"}'; exit 0 ;;
  open) echo '{"view":"list","title":"GitHub","placeholder":"Search issues and PRs…","search":"./search.sh rows"}' ;;
  rows) ;;
  *) echo "usage: search.sh open|rows [words] | approve <url> | comment <url> <text>" >&2; exit 64 ;;
esac
words=${2:-}
[ -n "$words" ] || words="involves:@me is:open"   # before you type: what involves you
gh search issues --include-prs --limit 30 --json number,title,url,repository,isPullRequest,state --jq '.[] |
  {title, subtitle: "\(.repository.nameWithOwner) · #\(.number) · \(.state)", open: .url, id: .url,
   icon: (if .isPullRequest then "arrow.triangle.pull" else "smallcircle.filled.circle" end),
   actions: ([{title: "Copy URL", copy: .url, icon: "link"}]
     + (if .isPullRequest then [{title: "Approve", run: "./search.sh approve \(.url | @sh)", icon: "checkmark.circle"}] else [] end)
     + [{title: "Comment…", run: "./search.sh comment \(.url | @sh)", icon: "text.bubble", arguments: [{placeholder: "Comment"}]}])}
  | tojson' -- "$words"
"""#

    static let bitbucketManifest = #"""
name = "Bitbucket"
description = "Your open PRs, PRs waiting on your review, and your repos, from Bitbucket Cloud or Data Center. Store the token in the Keychain: security add-generic-password -s euclid-bitbucket -a \"$USER\" -w '<token>'"

[source]
run = "./items.sh"
refresh_minutes = 5

[[action]]
name = "Search Bitbucket"
run  = 'open "https://bitbucket.org/search?q=$EUCLID_QUERY_URL"'

[settings]
# Cloud: your Atlassian email + an API token (id.atlassian.com › Security › API tokens).
# Data Center: base_url = "https://bitbucket.example.com" and an HTTP access token; no email.
email         = ""
base_url      = "https://api.bitbucket.org/2.0"
token_command = "security find-generic-password -s euclid-bitbucket -w"
repos         = []   # Cloud: where to look for review requests, e.g. ["team/app"]; default: your 10 latest repos
"""#

    static let bitbucketScript = #"""
#!/bin/sh
# Bitbucket PRs waiting on your review (also on the empty bar), your open PRs, and your repos.
set -eu
command -v jq >/dev/null 2>&1 || { echo "needs jq: brew install jq" >&2; exit 1; }
token=$(eval "$EUCLID_SETTING_TOKEN_COMMAND" 2>/dev/null) || token=""
[ -n "$token" ] || { echo "no Bitbucket token: security add-generic-password -s euclid-bitbucket -a \"$USER\" -w '<token>'" >&2; exit 1; }
base=${EUCLID_SETTING_BASE_URL:-https://api.bitbucket.org/2.0}
base=${base%/}
case $base in *api.bitbucket.org*) cloud=1 ;; *) cloud= ;; esac
if [ -n "$cloud" ] && [ -z "${EUCLID_SETTING_EMAIL:-}" ]; then
  echo "set your Atlassian email: [plugin.bitbucket] email = \"you@example.com\"" >&2; exit 1
fi

# GET a path; on failure say what Bitbucket said, not curl's noise.
get() {
  if [ -n "$cloud" ]; then
    out=$(curl -sS -m 15 -w '\n%{http_code}' -H 'Accept: application/json' -u "$EUCLID_SETTING_EMAIL:$token" "$base$1")
  else
    out=$(curl -sS -m 15 -w '\n%{http_code}' -H 'Accept: application/json' -H "Authorization: Bearer $token" "$base$1")
  fi
  code=$(printf '%s\n' "$out" | tail -n 1)
  case $code in
    2??) printf '%s\n' "$out" | sed '$d' ;;
    401|403) echo "Bitbucket said $code: check the email and token" >&2; return 1 ;;
    *) echo "Bitbucket said $code for ${1%%\?*}" >&2; return 1 ;;
  esac
}

if [ -n "$cloud" ]; then
  me=$(get /user)
  uuid=$(printf '%s' "$me" | jq -r '.uuid')
  repos=$(get "/repositories?role=member&sort=-updated_on&pagelen=100")
  mine=$(get "/pullrequests/$(jq -rn --arg u "$uuid" '$u | @uri')?state=OPEN&pagelen=50")
  pr='{title, subtitle: ([.destination.repository.full_name, "#\(.id)", .author.display_name] | map(select(.)) | join(" · ")),
       open: .links.html.href, id: .links.html.href, icon: "arrow.triangle.pull"}'
  # Cloud has no "review requests" endpoint: ask each repo for open PRs with you as a reviewer.
  slugs=${EUCLID_SETTING_REPOS:-$(printf '%s' "$repos" | jq -r '.values[:10][].full_name')}
  q=$(jq -rn --arg u "$uuid" '"state=\"OPEN\" AND reviewers.uuid=\"\($u)\"" | @uri')
  for slug in $slugs; do
    page=$(get "/repositories/$slug/pullrequests?q=$q&pagelen=50" 2>/dev/null) || continue
    printf '%s' "$page" | jq -c ".values[] | $pr + {label: \"Review\", suggest: true}"
  done
  printf '%s' "$mine" | jq -c ".values[] | $pr + {label: \"Your PR\"}"
  printf '%s' "$repos" | jq -c '.values[] | {title: .full_name, subtitle: (if (.description // "") == "" then "Repository" else .description end),
                                            open: .links.html.href, id: .links.html.href, icon: "folder", label: "Repo"}'
else
  pr='{title, subtitle: ([([.toRef.repository.project.key, .toRef.repository.slug] | map(select(.)) | join("/")), "#\(.id)", .author.user.displayName]
                         | map(select(. != null and . != "")) | join(" · ")),
       open: .links.self[0].href, id: .links.self[0].href, icon: "arrow.triangle.pull"}'
  review=$(get "/rest/api/1.0/dashboard/pull-requests?state=OPEN&role=REVIEWER&limit=50")
  mine=$(get "/rest/api/1.0/dashboard/pull-requests?state=OPEN&role=AUTHOR&limit=50")
  repos=$(get "/rest/api/1.0/profile/recent/repos?limit=100" 2>/dev/null) || repos='{"values":[]}'
  printf '%s' "$review" | jq -c ".values[] | $pr + {label: \"Review\", suggest: true}"
  printf '%s' "$mine" | jq -c ".values[] | $pr + {label: \"Your PR\"}"
  printf '%s' "$repos" | jq -c '.values[] | {title: ([.project.key, .slug] | map(select(.)) | join("/")),
                                            subtitle: (if (.description // "") == "" then "Repository" else .description end),
                                            open: .links.self[0].href, id: .links.self[0].href, icon: "folder", label: "Repo"}'
fi
"""#

    static let jiraManifest = #"""
name = "Jira"
description = "Jira issues assigned to you and ones you viewed lately; type a key (ABC-123) to open it. ⌘C copies the key, ⇧⌘C a branch name. Store the token in the Keychain: security add-generic-password -s euclid-jira -a \"$USER\" -w '<token>'"

[source]
run = "./items.sh"
refresh_minutes = 5

[answer]
run   = "./open.sh"
match = '^[A-Za-z][A-Za-z0-9_]+-[1-9][0-9]*$'

[[key]]
key  = "cmd+shift+c"
name = "Copy branch name"
when = ["jira"]
run  = "./branch.sh"

[settings]
# Cloud: base_url = "https://your-site.atlassian.net", your email and an API token.
# Data Center: your server's URL and a personal access token; no email.
base_url      = ""
email         = ""
token_command = "security find-generic-password -s euclid-jira -w"
jql           = "assignee = currentUser() AND statusCategory != Done ORDER BY updated DESC"
recent        = true   # also issues you viewed lately
"""#

    static let jiraItems = #"""
#!/bin/sh
# Jira issues matching `jql` (default: yours, not done), then ones you viewed lately.
# ↵ opens the issue, ⌘C copies its key.
set -eu
command -v jq >/dev/null 2>&1 || { echo "needs jq: brew install jq" >&2; exit 1; }
base=${EUCLID_SETTING_BASE_URL:-}; base=${base%/}
[ -n "$base" ] || { echo "set your Jira: [plugin.jira] base_url = \"https://your-site.atlassian.net\"" >&2; exit 1; }
token=$(eval "$EUCLID_SETTING_TOKEN_COMMAND" 2>/dev/null) || token=""
[ -n "$token" ] || { echo "no Jira token: security add-generic-password -s euclid-jira -a \"$USER\" -w '<token>'" >&2; exit 1; }
case $base in
  https://*.atlassian.net) path=/rest/api/3/search/jql  # Cloud retired /search in 2025
    [ -n "${EUCLID_SETTING_EMAIL:-}" ] || { echo "set your Atlassian email: [plugin.jira] email = \"you@example.com\"" >&2; exit 1; }
    auth="Basic $(printf '%s:%s' "$EUCLID_SETTING_EMAIL" "$token" | base64 | tr -d '\n')" ;;
  *) path=/rest/api/2/search
    auth="Bearer $token" ;;
esac

search() { # $1 = JQL, $2 = how many
  url="$base$path?jql=$(jq -rn --arg q "$1" '$q | @uri')&fields=summary,status,issuetype,project&maxResults=$2"
  out=$(curl -sS -m 15 -w '\n%{http_code}' -H 'Accept: application/json' -H "Authorization: $auth" "$url")
  code=$(printf '%s\n' "$out" | tail -n 1)
  case $code in
    2??) printf '%s\n' "$out" | sed '$d' ;;
    400) echo "Jira said 400: check jql" >&2; return 1 ;;
    401|403) echo "Jira said $code: check the email and token" >&2; return 1 ;;
    *) echo "Jira said $code for $path" >&2; return 1 ;;
  esac
}

row='{title: "\(.key) \(.fields.summary // "")",
      subtitle: ([.fields.status.name, .fields.issuetype.name, .fields.project.name] | map(select(.)) | join(" · ")),
      open: "\($base)/browse/\(.key)", id: .key, copy: .key, icon: "checklist", label: "Jira"}'
assigned=$(search "${EUCLID_SETTING_JQL:-assignee = currentUser() AND statusCategory != Done ORDER BY updated DESC}" 50)
printf '%s' "$assigned" | jq -c --arg base "$base" ".issues[] | $row + {suggest: true}"
[ "${EUCLID_SETTING_RECENT:-true}" = true ] || exit 0
# Recently viewed is a nice extra: an old server without issueHistory() shouldn't hide your issues.
recent=$(search "issuekey in issueHistory() ORDER BY lastViewed DESC" 30 2>/dev/null) || exit 0
printf '%s' "$recent" | jq -c --arg base "$base" --argjson seen "$(printf '%s' "$assigned" | jq '[.issues[].key]')" \
  ".issues[] | select(.key as \$k | \$seen | index(\$k) | not) | $row + {label: \"Viewed\"}" 2>/dev/null || true
"""#

    static let jiraOpen = #"""
#!/bin/sh
# A key you typed (abc-123), opened straight away. No network: it's instant.
set -eu
base=${EUCLID_SETTING_BASE_URL:-}; base=${base%/}
[ -n "$base" ] || exit 0
key=$(printf '%s' "$1" | tr '[:lower:]' '[:upper:]')
jq -nc --arg k "$key" --arg u "$base/browse/$key" '{title: $k, subtitle: "Open in Jira", open: $u, copy: $k, icon: "checklist"}'
"""#

    static let jiraBranch = #"""
#!/bin/sh
# ⇧⌘C on an issue: a git branch name like ABC-123-fix-login-on-safari.
set -eu
title=${EUCLID_ITEM_TITLE:-$1}
key=${title%% *}
summary=${title#"$key"}
# Drop accents (é → e), then keep letters and digits, joined by hyphens.
slug=$(printf '%s' "$summary" | perl -CSD -MUnicode::Normalize -pe '$_ = NFD($_); s/\p{Mn}//g' 2>/dev/null || printf '%s' "$summary")
slug=$(printf '%s' "$slug" | tr '[:upper:]' '[:lower:]' | sed -E 's/[^a-z0-9]+/-/g; s/^-+//; s/-+$//')
while [ ${#slug} -gt 40 ]; do
  case $slug in *-*) slug=${slug%-*} ;; *) slug=$(printf '%s' "$slug" | cut -c1-40) ;; esac
done
branch=$key${slug:+-$slug}
jq -nc --arg b "$branch" '{copy: $b, notice: "Copied \($b)"}'
"""#

    static let linearManifest = #"""
name = "Linear"
description = "Linear issues assigned to you. Store a personal API key (Linear › Settings › Security & access) in the Keychain: security add-generic-password -s euclid-linear -a \"$USER\" -w '<key>'"

[source]
run = "./items.sh"
refresh_minutes = 5

[settings]
token_command = "security find-generic-password -s euclid-linear -w"
limit = 50
"""#

    static let linearScript = #"""
#!/bin/sh
# Linear issues assigned to you and not done. ↵ opens the issue, ⌘C copies its ID (ENG-123).
set -eu
command -v jq >/dev/null 2>&1 || { echo "needs jq: brew install jq" >&2; exit 1; }
key=$(eval "$EUCLID_SETTING_TOKEN_COMMAND" 2>/dev/null) || key=""
[ -n "$key" ] || { echo "no Linear API key: security add-generic-password -s euclid-linear -a \"$USER\" -w '<key>'" >&2; exit 1; }
query='query($n: Int) { viewer { assignedIssues(first: $n, orderBy: updatedAt,
  filter: { state: { type: { nin: ["completed", "canceled"] } } }) {
  nodes { identifier title url state { name } team { key } } } } }'
jq -n --arg q "$query" --argjson n "${EUCLID_SETTING_LIMIT:-50}" '{query: $q, variables: {n: $n}}' |
  curl -fsS https://api.linear.app/graphql -H "Authorization: $key" -H 'Content-Type: application/json' --data @- |
  jq -c 'if .errors then error(.errors[0].message) else .data.viewer.assignedIssues.nodes[] end
         | {title, subtitle: "\(.identifier) · \(.state.name)", open: .url, id: .url, copy: .identifier,
            label: .team.key, icon: "checklist"}'
"""#

    static let slackManifest = #"""
name = "Slack"
description = "Jump to your Slack channels, and search messages with `slack <words>`. Needs a user token (xoxp-) with channels:read, groups:read and search:read, in the Keychain: security add-generic-password -s euclid-slack -a \"$USER\" -w '<token>'"

[source]
run = "./channels.sh"
refresh_minutes = 60

[answer]
run    = "./search.sh"
prefix = "slack"

[settings]
token_command = "security find-generic-password -s euclid-slack -w"
"""#

    static let slackChannels = #"""
#!/bin/sh
# Channels you're in; ↵ opens them in the Slack app.
set -eu
command -v jq >/dev/null 2>&1 || { echo "needs jq: brew install jq" >&2; exit 1; }
token=$(eval "$EUCLID_SETTING_TOKEN_COMMAND" 2>/dev/null) || token=""
[ -n "$token" ] || { echo "no Slack token: security add-generic-password -s euclid-slack -a \"$USER\" -w '<xoxp-token>'" >&2; exit 1; }
api() { curl -fsS -H "Authorization: Bearer $token" "https://slack.com/api/$1"; }
team=$(api auth.test | jq -r 'if .ok then .team_id else error(.error) end')
api "users.conversations?types=public_channel,private_channel&exclude_archived=true&limit=1000" |
  jq -c --arg team "$team" 'if .ok then .channels[] else error(.error) end
         | {title: "#\(.name)", subtitle: (.purpose.value // ""), open: "slack://channel?team=\($team)&id=\(.id)",
            id: .id, icon: (if .is_private then "lock" else "number" end)}'
"""#

    static let slackSearch = #"""
#!/bin/sh
# `slack deploy failed`: the 10 best matching messages; ↵ opens the message.
set -eu
token=$(eval "$EUCLID_SETTING_TOKEN_COMMAND" 2>/dev/null) || token=""
[ -n "$token" ] || { echo "no Slack token (see plugin.toml)" >&2; exit 1; }
q=$(jq -rn --arg q "$1" '$q | @uri')
curl -fsS -H "Authorization: Bearer $token" "https://slack.com/api/search.messages?count=10&query=$q" |
  jq -c 'if .ok then .messages.matches[] else error(.error) end
         | {title: (.text | gsub("\\s+"; " ") | .[0:140]), subtitle: "#\(.channel.name) · \(.username // "")",
            open: .permalink, id: .permalink, icon: "bubble.left", preview: .text}'
"""#

    static let tokensManifest = #"""
name = "Claude tokens"
description = "Today's Claude Code token use and cost on the bar, from ccusage. Click it for the full report."

[badge]
run   = "./today.sh"
icon  = "gauge.with.dots.needle.33percent"
refresh_minutes = 5
click = 'ghostty-run tab npx -y ccusage@latest daily'
"""#

    static let tokensScript = #"""
#!/bin/sh
# Prints today's Claude Code usage for the badge, e.g. "1.2M tok · $4.10". Needs Node (npx) and jq.
set -eu
command -v jq >/dev/null 2>&1 || { echo "needs jq: brew install jq" >&2; exit 1; }
if command -v ccusage >/dev/null 2>&1; then set -- ccusage; else set -- npx -y ccusage@latest; fi
"$@" daily --since "$(date +%Y%m%d)" --json |
  jq -r '[.totals.totalTokens // 0, .totals.totalCost // 0] | @tsv' |
  awk -F '\t' '{ t = $1 + 0
                 s = t >= 1e6 ? sprintf("%.1fM", t / 1e6) : t >= 1e3 ? sprintf("%.0fk", t / 1e3) : t
                 printf "%s tok · $%.2f\n", s, $2 }'
"""#

    static let defineManifest = #"""
name = "Dictionary"
description = "`define serendipity`: the macOS Dictionary's definition. ↵ opens it in Dictionary, ⌘C copies it."

[answer]
run    = 'osascript -l JavaScript ./define.js "$1"'
prefix = "define"
"""#

    static let defineScript = #"""
// The definition from the dictionaries you turned on in Dictionary.app, via Dictionary Services.
ObjC.import('CoreServices')

function run(argv) {
  const word = argv.join(' ')
  const open = 'dict://' + encodeURIComponent(word)
  const ref = $.DCSCopyTextDefinition(null, $(word), $.NSMakeRange(0, word.length))
  const text = ref ? ObjC.unwrap(ObjC.castRefToObject(ref)) : ''
  if (!text) return JSON.stringify({ title: 'No definition for “' + word + '”', subtitle: 'Open Dictionary', open, icon: 'character.book.closed' })
  return JSON.stringify({
    title: text.replace(/\s+/g, ' ').slice(0, 140), subtitle: word + ' · Dictionary',
    open, copy: text, preview: text, id: open, icon: 'character.book.closed',
  })
}
"""#

    static let currencyManifest = #"""
name = "Currency"
description = "`100 usd to eur`: converts with daily rates from open.er-api.com (free, no key). ↵ copies the amount."

[answer]
run    = "./convert.sh"
match  = '(?i)^\d[\d,.]*\s*[a-z]{3}\s+(to|in)\s+[a-z]{3}$'
prefix = "cur"      # or `cur 100 usd eur`
"""#

    static let currencyScript = #"""
#!/bin/sh
# Rates are cached for an hour outside this folder (writing here would reload the plugin).
set -euf
command -v jq >/dev/null 2>&1 || { echo "needs jq: brew install jq" >&2; exit 1; }
# "100usd TO eur" → 100 USD EUR
set -- $(printf '%s' "$1" | tr 'a-z' 'A-Z' | sed -E 's/,//g; s/([0-9])([A-Z])/\1 \2/; s/ (TO|IN) / /')
[ $# -eq 3 ] || { echo "try: 100 usd to eur" >&2; exit 1; }
amount=$1 from=$2 to=$3
cache="${TMPDIR:-/tmp}/euclid-rates-$from.json"
if [ ! -s "$cache" ] || [ -n "$(find "$cache" -mmin +60)" ]; then
  # Not a currency (e.g. `10 kgs in lbs`): show nothing.
  curl -fsS --max-time 1.5 "https://open.er-api.com/v6/latest/$from" > "$cache.tmp" 2>/dev/null || { rm -f "$cache.tmp"; exit 0; }
  mv "$cache.tmp" "$cache"
fi
jq -c --arg to "$to" --arg from "$from" --arg n "$amount" '
  select(.result == "success" and .rates[$to] != null)
  | ($n | tonumber) as $a | .rates[$to] as $r | ($a * $r * 100 | round / 100 | tostring) as $v
  | {title: "\($v) \($to)", subtitle: "\($n) \($from) · 1 \($from) = \($r) \($to) · \(.time_last_update_utc)",
     copy: $v, icon: "dollarsign.arrow.circlepath", label: "Currency"}' "$cache"
"""#

    static let contactsManifest = #"""
name = "Contacts"
description = "People in Contacts by name, company, email or phone. ↵ opens the card, ⌘C copies the email. macOS asks once for access."

[source]
run = "osascript -l JavaScript ./people.js"
refresh_minutes = 60
"""#

    static let contactsScript = #"""
// Everyone in Contacts, one JSON line each. Reads whole columns at once, which is fast.
function run() {
  const people = Application('Contacts').people
  const ids = people.id(), names = people.name(), orgs = people.organization()
  const emails = people.emails.value(), phones = people.phones.value()
  return ids.map((id, i) => {
    const name = names[i] || orgs[i]
    if (!name) return null
    const email = (emails[i] || [])[0], phone = (phones[i] || [])[0]
    return JSON.stringify({
      title: name, subtitle: [orgs[i] !== name ? orgs[i] : null, email, phone].filter(Boolean).join(' · '),
      open: 'addressbook://' + id, copy: email || phone || name, id, icon: 'person.crop.circle',
    })
  }).filter(Boolean).join('\n')
}
"""#

    static let shortcutsManifest = #"""
name = "Shortcuts"
description = "Your Shortcuts by name. ↵ runs one."

[source]
run = "./list.sh"
refresh_minutes = 30

[[action]]
name = "Open in Shortcuts"
run  = 'open "shortcuts://open-shortcut?name=$EUCLID_QUERY_URL"'
"""#

    static let shortcutsScript = #"""
#!/bin/sh
# One row per shortcut; ↵ runs it with the shortcuts CLI.
set -eu
command -v jq >/dev/null 2>&1 || { echo "needs jq: brew install jq" >&2; exit 1; }
shortcuts list | jq -Rc 'select(length > 0)
  | {title: ., subtitle: "Shortcut", run: "shortcuts run \(@sh)", id: ., icon: "square.2.layers.3d"}'
"""#

    static let cleanlinksManifest = #"""
name = "Clean links"
description = "A mod: copy a link with tracking junk (utm_*, fbclid, gclid…) and the clipboard gets the clean one."

[[on]]
event = "clipboard"
run   = "./clean.sh"
"""#

    static let cleanlinksScript = #"""
#!/bin/sh
# Gets the copied text as $1. Prints {"copy": …} only when there was something to remove.
set -eu
case "$1" in http://*|https://*) ;; *) exit 0 ;; esac
case "$1" in *"
"*) exit 0 ;; esac  # one line only
clean=$(printf '%s\n' "$1" | awk '{
  n = index($0, "#"); frag = n ? substr($0, n) : ""; url = n ? substr($0, 1, n - 1) : $0
  q = index(url, "?"); if (!q) { print $0; exit }
  k = split(substr(url, q + 1), parts, "&"); out = ""
  for (i = 1; i <= k; i++)
    if (parts[i] != "" && parts[i] !~ /^(utm_[a-z_]+|fbclid|gclid|dclid|mc_eid|igshid|_hsenc|_hsmi)=/)
      out = out (out == "" ? "" : "&") parts[i]
  print substr(url, 1, q - 1) (out == "" ? "" : "?" out) frag }')
[ "$clean" = "$1" ] && exit 0
esc=$(printf '%s' "$clean" | sed 's/\\/\\\\/g; s/"/\\"/g')
printf '{"copy":"%s","notice":"Cleaned a tracking link"}\n' "$esc"
"""#

    static let revealManifest = #"""
name = "Reveal in Finder"
description = "A mod: ⇧⌘R on a file, project or app shows it in Finder."

[[key]]
key  = "cmd+shift+r"
name = "Reveal in Finder"
when = ["file", "project", "app"]
run  = 'open -R "$1"'
"""#

    static let aiManifest = #"""
name = "AI"
description = "`ai <question>` answers in the bar; on a clip, fix, translate or explain it. Apple's on-device model by default (free, private), or the claude, codex or gemini CLI you're logged into. No API key."

# `ai what is a monad` then ↵: the answer shows in the bar (→ reads it all, ↵ copies).
[answer]
prefix   = "ai"
on_enter = true
run      = './ai.sh answer "Answer briefly and plainly." "$1"'

# Copy some text, open Euclid: the clip is on top. These keys act on it.
[[key]]
key  = "cmd+shift+f"
name = "Fix writing"
when = ["clip", "snippet"]
run  = './ai.sh paste "Fix the spelling and grammar of the text below. Keep its meaning, tone, language and formatting. Reply with only the corrected text." "$1"'

[[key]]
key  = "cmd+shift+t"
name = "Translate"
when = ["clip", "snippet"]
run  = './ai.sh paste "Translate the text below into $EUCLID_SETTING_LANGUAGE. Keep its formatting. Reply with only the translation." "$1"'

[[key]]
key  = "cmd+shift+e"
name = "Explain"
when = ["clip", "snippet"]
run  = './ai.sh show "Explain the text below briefly and plainly. If it is code or an error, say what it does or what went wrong." "$1"'

# On an answer: ⇧⌘↵ opens a terminal running your AI CLI with the question and answer, to keep going there.
[[key]]
key  = "cmd+shift+return"
name = "Continue in terminal"
when = ["ai"]
run  = "./continue.sh"

[settings]
cli      = ""          # empty: Apple's on-device model (macOS 26, Apple Intelligence on), else the first
                       # of claude, codex, gemini on your PATH. Or any command that takes the prompt as
                       # its last argument, e.g. "ollama run llama3.2"
language = "English"   # what Translate translates into
terminal = ""          # how Continue in terminal opens one: empty = Ghostty if you have it, else Terminal;
                       # or a command that runs its arguments, e.g. "ghostty-run window"
"""#

    static let aiScript = #"""
#!/bin/sh
# ./ai.sh answer|paste|show "<instruction>" "<text>"
# Asks an AI model and prints what Euclid should do with the reply (one JSON line):
#   answer  an answer row in the bar     paste  type it into the app you were in
#   show    open the bar with it to read
set -eu
mode=$1 prompt="$2

$3"
cli=${EUCLID_SETTING_CLI:-}
if [ -z "$cli" ]; then
  if [ -n "${EUCLID_BAR:-}" ] && "$EUCLID_BAR" --ai --check 2>/dev/null; then
    cli=apple
  else
    for c in claude codex gemini; do
      if command -v "$c" >/dev/null 2>&1; then cli=$c; break; fi
    done
  fi
fi
[ -n "$cli" ] || {
  echo "no AI model: turn on Apple Intelligence (macOS 26), install claude, codex or gemini, or set [plugin.ai] cli" >&2
  exit 1
}

case "$cli" in
  apple)  answer=$("$EUCLID_BAR" --ai "$prompt" </dev/null) ;;
  claude) answer=$(claude -p "$prompt" </dev/null) ;;
  gemini) answer=$(gemini -p "$prompt" </dev/null) ;;
  codex)
    last=$(mktemp)
    codex exec --skip-git-repo-check --output-last-message "$last" "$prompt" </dev/null >/dev/null
    answer=$(cat "$last"); rm -f "$last" ;;
  *) answer=$(eval "$cli \"\$prompt\"" </dev/null) ;;
esac
[ -n "$answer" ] || { echo "$cli gave no answer" >&2; exit 1; }

# JSON-encode with JavaScript for Automation (always on macOS).
osascript -l JavaScript -e '
function run(argv) {
  const [mode, cli, answer] = argv
  if (mode === "paste") return JSON.stringify({ paste: answer })
  if (mode === "show") return JSON.stringify({ show: answer })
  const first = answer.split("\n").find(l => l.trim()) || answer
  return JSON.stringify({
    title: first.length > 140 ? first.slice(0, 139) + "…" : first,
    subtitle: (cli === "apple" ? "Apple on-device" : cli) + " · → reads it all · ↵ copies",
    copy: answer, preview: answer, icon: "sparkles", id: "ai-answer",
  })
}' "$mode" "$cli" "$answer"
"""#

    static let aiContinue = #"""
#!/bin/sh
# ⇧⌘↵ on an `ai` answer: a terminal running your AI CLI, already told the question and the answer,
# so you can keep going there. The bar keeps no chat history; the CLI has its own.
set -eu
question=${EUCLID_SEARCH:-}
question=${question#ai }
answer=${EUCLID_ITEM_TEXT:-}
[ -n "$answer" ] || { echo "press ↵ for an answer first" >&2; exit 1; }
cli=${EUCLID_SETTING_CLI:-}
case $cli in claude*|codex*|gemini*) cli=${cli%% *} ;; *) cli= ;; esac  # Apple's model and others have no chat
if [ -z "$cli" ]; then
  for c in claude codex gemini; do
    if command -v "$c" >/dev/null 2>&1; then cli=$c; break; fi
  done
fi
[ -n "$cli" ] || { echo "Continue in terminal needs the claude, codex or gemini CLI" >&2; exit 1; }
prompt="I asked a quick question and got this answer. Keep it in mind and wait for my follow-up; reply only \"Go ahead.\" for now.

Question: $question

Answer: $answer"
case $cli in gemini) set -- gemini -i "$prompt" ;; *) set -- "$cli" "$prompt" ;; esac

term=${EUCLID_SETTING_TERMINAL:-}
if [ -z "$term" ] && { [ -d /Applications/Ghostty.app ] || [ -d "$HOME/Applications/Ghostty.app" ]; }; then
  term="ghostty-run tab"
fi
if [ -n "$term" ]; then
  $term "$@"
else
  # Terminal.app runs a command line: quote each argument for the shell, then for AppleScript.
  line=$(for a in "$@"; do printf "'%s' " "$(printf '%s' "$a" | sed "s/'/'\\\\''/g")"; done)
  osascript - "$line" <<'APPLESCRIPT' >/dev/null
on run argv
  tell application "Terminal"
    do script (item 1 of argv)
    activate
  end tell
end run
APPLESCRIPT
fi
"""#

    public static let guide = marker + "\n" + #"""
# Euclid plugins

A plugin is a folder here with a `plugin.toml` and the scripts it runs. It can add things
to the bar (search items, answers, badges, actions) or change how Euclid behaves (hooks and
keys: a "mod"). Euclid reloads it when you save, so write it, try it, and it's live. This file is the whole format.

## Make one (people and coding agents)

1. Make a folder: `~/.config/euclid/plugins/<id>/` (lowercase, no spaces; the id is the folder name).
2. Write `plugin.toml` and a script (any language; make it executable with `chmod +x`).
3. Try it: `/Applications/Euclid.app/Contents/MacOS/euclid-bar --try-plugin <id> [query]`.
   It runs every part once and prints the rows, the badge text or the exact error. Fix and repeat.
4. It's already live: open Euclid (⌥Space). Problems show in the footer and in `--check-config`.

## plugin.toml

```toml
name = "GitHub"                    # shown as the section title
description = "What it does, one line"

[source]                           # items in search, refreshed in the background
run = "./items.sh"                 # runs in this folder, in your login shell
refresh_minutes = 5                # 1–1440, default 10

[answer]                           # replies to what you type, below the instant results
run    = "./tz.sh"                 # gets the text as $1 (and $EUCLID_QUERY)
prefix = "tz"                      # `tz 3pm` runs it with "3pm"
match  = '^\d+(am|pm)$'            # and/or: runs on the whole query when it matches
                                   # one of the two is required; 2 s limit
on_enter = true                    # optional: show “Ask”, run on ↵ with up to 60 s (an AI model)

[badge]                            # a short status chip on the search bar
run   = "./today.sh"               # first line of output, up to 40 characters; empty = hidden
icon  = "gauge"                    # optional SF Symbol name
refresh_minutes = 5                # default 5
click = 'ghostty-run tab ccusage'  # optional: runs when you click the badge

[[action]]                         # added to ⌘K, after your own actions
name = "Search GitHub code"
run  = 'open "https://github.com/search?type=code&q=$EUCLID_QUERY_URL"'

[settings]                         # defaults; users override in config.toml: [plugin.<id>]
limit = 30                         # scripts get $EUCLID_SETTING_LIMIT
```

Every part is optional, but a plugin needs at least one of `[source]`, `[answer]`, `[badge]`
or `[[action]]`.

## What scripts print

One JSON object per line (or a single JSON array). Only `title` is required.

```json
{"title":"Fix login on Safari","subtitle":"acme/web · #412","open":"https://github.com/acme/web/pull/412","label":"Review","suggest":true}
```

| Field | Meaning |
|---|---|
| `title` | The row's text (searched) |
| `subtitle` | Second line (searched) |
| `open` | `↵` opens this URL or file path |
| `paste` | `↵` pastes this text into the app you were in |
| `copy` | `↵` copies this text (and `⌘C` copies it) |
| `run` | `↵` runs this shell command in the plugin folder |
| `icon` | SF Symbol name (`arrow.triangle.pull`), an emoji (`🌤`) or an image file path (`~/pics/a.png`, or relative to the plugin folder) |
| `label` | Shown on the right; default: the plugin's name |
| `preview` | Text for the preview pane (`→`) |
| `id` | Stable identity, so Euclid learns what you pick; default: `open`, then `title` |
| `suggest` | `true` = also shown when the search box is empty (3 per plugin) |
| `arguments` | Up to 3 fields to fill in before `run` runs (see below) |
| `actions` | More things to do with it, shown by `⌘K`: a list of items like this one (up to 20) |

`↵` does the first of `open`, `paste`, `copy`, `run` that is set, else its first action. All fields are strings except
`suggest` and `arguments`. Print errors to stderr and exit non-zero: Euclid shows the first stderr line.

### Arguments: ask before running

An item with `run` can ask for up to 3 values first. `↵` shows the fields in the search bar
(`tab` moves between them, `↵` runs, `esc` cancels); the values reach `run` as `$1`–`$3` and
`$EUCLID_ARG_1`–`3`. Same format as a Raycast script's `@raycast.argument1`:

```json
{"title":"Weather","run":"./weather.sh","arguments":[
  {"type":"text","placeholder":"City"},
  {"type":"dropdown","placeholder":"Units","optional":true,"data":[{"title":"Metric","value":"m"},{"title":"US","value":"u"}]}]}
```

`type` is `text` (default), `password` (hidden as you type) or `dropdown` (pick one of `data`;
the script gets its `value`). `optional: true` fields may stay empty.

### What `run` prints: effects and views

When `↵` runs an item's `run` (or you click a badge), Euclid reads what it prints, like a key's
output (see Mods below): `{"notice":"Volume 40%"}` shows in the footer with the panel still
open, `{"copy":…}`, `{"paste":…}`, `{"open":…}` and `{"show":…}` work too. It waits up to 1 s
with the panel open; a slower command keeps going in the background and its effects still apply.

A script can also open a view in the panel by printing a header line first:

```sh
echo '{"view":"grid","title":"Emoji","placeholder":"Search emoji…","columns":8}'
echo '{"title":"grinning face","icon":"😀","paste":"😀"}'     # items, as a source prints them
```

| View | Shows |
|---|---|
| `list` | The item lines after the header, as rows. Typing filters them. |
| `grid` | The same, as tiles: big `icon` (emoji, image or symbol) with the title under it. `columns`: 3–10, default 6. |
| `detail` | Everything printed after the header, as text to read; `"code":true` for monospaced output. `↵` or `⌘C` copies it. |

`esc` goes back. Items in a view work like any item, so a `run` can open another view
(a confirm step, a drill-down).

**Actions.** An item's `actions` are items too (`open`, `copy`, `run`, `arguments`…). `⌘K` on it
opens them as a list; `↵` runs one and goes back, and a live view under it reloads:

```json
{"title":"Fix login","open":"https://github.com/acme/web/pull/412","actions":[
  {"title":"Copy URL","copy":"https://github.com/acme/web/pull/412"},
  {"title":"Approve","run":"gh pr review https://github.com/acme/web/pull/412 --approve"},
  {"title":"Comment…","run":"./comment.sh 412","arguments":[{"placeholder":"Comment"}]}]}
```

**Search as you type.** Add `"search":"./find.sh"` to a list or grid header and Euclid hands what
you type to that command as `$1` after each pause (0.15 s), and shows exactly the rows it prints
(no header needed). Use it when only the script can search: an API, a server, a big index.

**Live views.** Add `"reload"` to the header, a command that prints the view again, and Euclid
keeps it current without the script remembering anything: it reruns it after a `run` in the view
that printed no new view (a kill, a stop), when you come back to it with `esc`, and every
`refresh_seconds` (1–3600) while it's on screen. The rows change in place: your filter text stays
and the selection follows its item (give items an `id`). Only one reload runs at a time, and none
while the panel is closed. Keep `reload` fast (well under a second): it's the whole refresh.

```sh
echo '{"view":"list","title":"Processes","reload":"./list.sh","refresh_seconds":3}'
```

### dmenu: pick from any list

`euclid-bar --pick` reads lines from stdin, opens the panel to pick one and prints it
(exit 1 if you press `esc`). Lines can be plain text or JSON items (for icons and subtitles);
the chosen line is printed exactly as it came in. `--grid` shows tiles, `--prompt "Branch"`
sets the placeholder.

```sh
git branch --format='%(refname:short)' | euclid-bar --pick --prompt Branch | xargs git switch
```

## What scripts get

- Working directory: the plugin folder. `$EUCLID_PLUGIN_DIR` is its path.
- `$1` and `$EUCLID_QUERY`: the text (answers and actions); `$EUCLID_QUERY_URL`: URL-encoded.
- `$EUCLID_SETTING_<KEY>` for each setting, uppercased.
- `~/.config/euclid/bin` first on PATH: `ghostty-run tab|split|window <cmd>` opens a
  terminal running a command.
- `[env]` from config.toml. Scripts run in a login shell, so Homebrew tools are on PATH.

The text you type is only ever passed as `$1` and environment variables, never pasted into a
command, so quote it: `"$1"`.

## Mods: hooks and keys

A plugin can also change how Euclid behaves. Same folder, same scripts.

```toml
[[on]]                             # run when something happens
event = "clipboard"                # clipboard: you copied text ($1 = the text)
run   = "./clean.sh"               # open: the panel opened ($1 = the app you were in)
                                   # choose: you picked a result with ↵ ($1 = its URL, path or text)
                                   # app: you switched apps ($1 = the app's name)

[[key]]                            # a shortcut in the panel, on the selected result
key  = "cmd+g"                     # needs a modifier; Euclid's own keys (⌘K, ⌘C, ⌘/, ⌘1…) are taken
name = "Open in GitHub Desktop"    # shown in the footer when it applies
when = ["github", "project"]       # optional: kinds it applies to, or a plugin's id
run  = 'open -a "GitHub Desktop" "$1"'   # $1 = the result's URL, path or text
```

Kinds: `app` `project` `file` `clip` `snippet` `note` `history` `action` `answer`
`command` `plugin` (a plugin's own items also match their plugin's id). Keys and `choose` hooks
also get `$EUCLID_ITEM_KIND`, `_TITLE`, `_SUBTITLE`, `_URL`, `_PATH`, `_TEXT` and `_PLUGIN`.

A hook or key script can ask Euclid to do something by printing JSON lines (anything else it
prints is ignored):

```json
{"notice":"Cleaned a tracking link"}   shown in the panel's footer
{"copy":"https://example.com/x"}       put on the clipboard (a clipboard hook doesn't see its own copy)
{"paste":"Fixed text"}                 keys only: paste into the app you were in
{"show":"A long answer…"}              keys only: open the panel with this text to read
{"open":"https://example.com"}         open a URL or file
{"query":"jira "}                      open hooks only: start the search with this text
```

Hooks run in the background with a 10 s limit and never slow the panel down; keys get 60 s
(enough for an AI CLI). Try one with
sample text: `euclid-bar --try-plugin <id> "https://example.com/?utm_source=x"`. Keys aren't run
by `--try-plugin`; it checks them and lists them.

## Port a Raycast extension

Most Raycast extensions are an API or a CLI plus lists, and port to a plugin. Ask your agent:

> Port the Raycast extension at <github.com/raycast/extensions/tree/main/extensions/NAME> to a
> Euclid plugin in ~/.config/euclid/plugins/NAME. Read its package.json and src/ to see each
> command and what it calls, then follow ~/.config/euclid/plugins/AGENTS.md:
> a command with a list → a source row whose `run` opens a list view; `<List.Item>` → an item;
> its `<ActionPanel>` → the item's `actions` (first one = ↵); `onSearchTextChange` that calls a
> server → `"search"`; `useCachedPromise` / `setInterval` / `revalidate` → `"reload"` with
> `refresh_seconds`; `<Detail markdown>` → a detail view; `<Form>` with ≤3 fields → `arguments`;
> preferences → `[settings]`; tokens → the Keychain (`security find-generic-password`).
> Prefer the service's CLI (gh, docker, brew, kubectl) over raw HTTP. Keep each script fast.
> Check it with `euclid-bar --try-plugin NAME` until it runs clean, and tell me what you left out.

What doesn't port: extensions that need Raycast's AI, a browser extension, window management, or
forms with more than 3 fields. Worked examples: `docker` and `kill-process` (Raycast has both),
`github` (search, actions).

## Rules of thumb

- Keep sources fast and quiet: they run in the background with a 30 s limit, answers with 2 s.
- Put secrets in the Keychain and read them in the script:
  `security find-generic-password -s my-service -w`. Never in plugin.toml.
- At most 2,000 items per source.
- A team can share plugins from a repo: `[plugins] paths = ["~/work/team/euclid-plugins"]`.
- Turn one off without deleting it: `[plugins] disabled = ["<id>"]`.

## Examples

`euclid-bar --plugin add <name>` writes a working example into this folder. Read them, copy them,
change them:

- `github`: your PRs, review requests and issues, through the `gh` CLI; ⌘K copies, approves or
  comments; `gh <words>` searches issues and PRs as you type (a source, `actions`, a `search` view).
- `linear`: Linear issues assigned to you, through the GraphQL API (a source, key in the Keychain).
- `bitbucket`: your PRs, review requests and repos, Cloud or Data Center (a source, token in the Keychain).
- `jira`: your issues and ones you viewed; `ABC-123` opens any issue; ⇧⌘C copies a branch name
  (a source, an answer with a `match`, and a `[[key]]`).
- `slack`: jump to channels, and `slack <words>` searches messages (a source and an answer).
- `tokens`: today's Claude Code tokens and cost on the bar, through `ccusage` (a badge).
- `define`: `define <word>` from the macOS Dictionary, in JavaScript for Automation (an answer).
- `currency`: `100 usd to eur` with daily rates, cached (an answer with a `match`).
- `contacts`: people in Contacts, through JavaScript for Automation (a source).
- `shortcuts`: run your Shortcuts, through the `shortcuts` CLI (a source and an action).
- `cleanlinks`: strips tracking parameters from links you copy (a `clipboard` hook).
- `reveal`: ⇧⌘R shows the selected file, project or app in Finder (a `[[key]]`).
- `ai`: `ai <question>` answers in the bar; on a clip ⇧⌘F fixes the writing and pastes it back,
  ⇧⌘T translates, ⇧⌘E explains; ⇧⌘↵ on an answer continues in a terminal with your AI CLI.
  Apple's on-device model by default, or the `claude`, `codex` or `gemini` CLI you're logged into
  (an `on_enter` answer and `[[key]]`s).
- `raycast`: runs Raycast script commands from a folder (default `~/.config/euclid/raycast`):
  each script is a row, `rc <name> <args>` runs one with arguments. Reads `@raycast.title`, `mode`
  (silent, compact, fullOutput, inline), `argument1`–`3`, `needsConfirmation`, `icon`,
  `packageName` and `currentDirectoryPath`. Clone github.com/raycast/script-commands and pick some
  (a source, an answer, views and arguments).
- `emoji`: “Emoji” opens a grid of every emoji; `emoji heart` lists matches. ↵ pastes (a grid view).
- `volume`: Volume Up / Down / Mute rows, `vol 40`, and Set Volume with a dropdown (effects and arguments).
- `kill-process`: your processes, busiest first, refreshing every 3 s; ↵ quits one, ↵ again
  force-quits; `kill chrome` finds one (a live view and an answer).
- `docker`: your containers, live: logs (live too), a shell, open its port, start, stop, restart
  (live views that drill down).
"""#
}
