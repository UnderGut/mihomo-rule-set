# mihomo-rule-set

Rule-sets for Mihomo (clash-meta): hand-maintained source lists plus
auto-compiled `.mrs`, all kept in a single `rules/` directory.

## Layout

```
├── README.md  .gitignore  .gitattributes
├── build.sh            # builder: fetch -> validate -> compile .mrs into rules/
├── sources.list        # per-source upstreams (one domain list -> one .mrs)
├── merge.list          # merge groups (N domain sources -> one merged .mrs)
├── ip.list             # IP groups (IP lists -> one ipcidr .mrs)
├── .github/workflows/  # generate-rules.yml (daily + on input changes), ban-ru-onru.yml (weekly), svg-to-png.yml
├── .github/scripts/    # check-rules.sh (gate before publishing), check-yaml.sh (lint rules/*.yaml),
│                       # ban-ru-onru.py (category-ban-ru domains hosted on Russian IPs)
├── rules/              # rule-sets (BOTH hand-written sources and compiled .mrs)
└── icon/               # proxy-group icons (svg + generated png)
```

`build.sh` only **writes its own `.mrs`** into `rules/` — it never deletes the
hand-maintained files. Sources and compiled outputs live side by side.

| File | behavior | maintained by |
|---|---|---|
| `rules/*.yaml` (drop, games, in-direct, in-proxy, ru-inline) | classical | by hand |
| `rules/tiktok-extra.list` | plain domain list, input of the `tiktok` merge group | by hand |
| `rules/<name>_domain.mrs` (from `sources.list`) | domain | CI |
| `rules/<group>.mrs` (from `merge.list`: ai, music, tiktok, games-mobile, community, category-ban-ru, wld) | domain | CI |
| `rules/<group>.mrs` (from `ip.list`: geoip-for-ru-v4, wl-ru-ip-v4) | ipcidr | CI |
| `rules/category-ban-ru-onru.mrs` (from `ban-ru-onru.yml`) | domain | CI, weekly |

`games-mobile.mrs` is the `DOMAIN`/`DOMAIN-SUFFIX` part of `rules/games.yaml`
(for clients without `PROCESS-NAME` support). Output names are part of the
contract: clients and mirrors fetch them by path — do not rename.

## Build locally

```bash
bash ./build.sh      # needs `mihomo` (convert-ruleset) and `curl` on PATH
```

Use the same mihomo version as CI (`MIHOMO_VERSION` in
`.github/workflows/generate-rules.yml`): `.mrs` bytes depend on it, so a
locally built file differs from the CI one even with identical rules. Prefer
letting CI publish the `.mrs`; commit only the inputs.

## Add a per-source rule (one upstream -> one .mrs)

Append to `sources.list` — `category,url` (the first field is informational;
output is flat `rules/<url basename>_domain.mrs`). Only plain domain lists
(`.txt`/`.list`, Clash domainset: `example.com`, `+.example.com`) are supported:

```
games,https://example.com/rules/games.txt
```

## Add a merge group (N upstreams -> one .mrs)

Append to `merge.list` — `group,type,url[,exclude_regex]`:

```
music,list,https://github.com/MetaCubeX/meta-rules-dat/raw/meta/geo/geosite/spotify.list
music,yaml,https://github.com/blackmatrix7/ios_rule_script/raw/master/rule/Clash/Qobuz/Qobuz.yaml,(^|\.)qobuz-typo\.
```

- type `list` = plain domain list (MetaCubeX `.list`, `+.` notation kept)
- type `suffixlist` = plain list where a bare `example.com` means the domain and its
  subdomains (Re-filter `community.lst`): written as `+.example.com`
- type `yaml` = classical `.yaml` (blackmatrix7): `DOMAIN`/`DOMAIN-SUFFIX` kept, rest dropped
- type `locallist` / `localyaml` = the same formats, read from a file in this repo
  (e.g. `tiktok,locallist,rules/tiktok-extra.list` adds hosts missing upstream)
- `exclude_regex` (optional, ERE): matching domains are dropped
- output: `rules/<group>.mrs` (behavior `domain`)

## Add an IP group (IP lists -> one ipcidr .mrs)

Append to `ip.list` — `group,family,url[,min_entries[,noratio]]`:

```
geoip-for-ru-v4,v4,https://raw.githubusercontent.com/Davoyan/mihomo-rule-sets/main/ip-for-ru/lists/ips-for-ru.txt,10000
```

- family `v4` = IPv4 CIDRs kept, IPv6 lines dropped (the only family implemented)
- url = `http(s)://…` or `local:<path in this repo>`
- `min_entries` (optional) = absolute floor, protects the very first build; replaces the
  default 100 (a small curated list such as `wl-ru-ip-v4` has ~90 prefixes)
- `noratio` (optional) = skip the ratio checks against the previous build (a small
  curated list grows or shrinks by tens of percent legitimately); other checks stay
- output: `rules/<group>.mrs` (behavior `ipcidr`)

## category-ban-ru-onru (weekly + after a Generate run that changed category-ban-ru.mrs)

`category-ban-ru` (RKN registry, ~23k `.ru`/`.su`/`.рф` domains) changes routing only for
domains that would otherwise hit a DIRECT rule: unmatched traffic already goes to the proxy,
and a domain on a foreign IP never matches `geoip-for-ru`. `ban-ru-onru.yml` resolves every
entry over DNS-over-HTTPS (Cloudflare, Google as fallback) and keeps only those with an A
record inside `geoip-for-ru-v4` — about 12% of the list (a third no longer resolves at all).
Use it instead of the full list where memory matters (iOS). Guards: ≥90% of lookups answered,
200..15000 entries, no shrink below 60% of the previous build; lookups that fail keep their
previous verdict.

## Safety: when an output is NOT updated

A failing output keeps its previous `.mrs`; the run turns red and lists the
reason (see the run summary). Nothing broken is ever published.

- **Every output**: sources are fetched with `curl -f` and retries (HTTP errors,
  empty files and HTML error pages fail); mihomo must compile it without a
  single warning (mihomo silently drops invalid lines otherwise) and the result
  must read back; the entry count must be at least 80% of the previous build
  (`SOURCE_MIN_RATIO` / `MERGE_MIN_RATIO`).
- **sources.list / merge groups**: every line must be a domain; merge groups
  also reject TLDs and public suffixes according to the
  [Public Suffix List](https://publicsuffix.org/): ICANN suffixes (`+.com`,
  `+.co.uk`) in every group, PRIVATE ones (`+.github.io`, `+.akamaized.net`)
  only in `PSL_STRICT_GROUPS` (default `tiktok`).
- **IP groups**: every line must be a strict CIDR (no bare IPs, no host bits,
  mask `/10`…`/32`); special-purpose ranges (private, CGNAT, loopback,
  fake-ip `198.18/15`, multicast…) are rejected; prefix count ≥ 80% and address
  count within 90–120% of the previous build.
- **Gate before publishing** (`.github/scripts/check-rules.sh`): every changed
  `rules/*.mrs` must decode, keep its behavior, contain only valid entries and
  not shrink below 80% of the committed version — otherwise the committed
  version is restored.
- **Hand-written `rules/*.yaml`** are linted (`.github/scripts/check-yaml.sh`):
  `payload:` key, `  - ` items, known rule types, no tabs.

A legitimate big upstream change: run the workflow manually
(Actions → Generate mihomo Rules → Run workflow, branch `main`) with a lower
`min_ratio` (entry-count checks) or, for an IP group, its name in
`force_groups` (skips all checks against the previous build). A manual run from
another branch is a dry run: it builds and checks but never pushes.

## CI

- **generate-rules.yml** — daily at 07:17 UTC, on every push to `main` that
  touches the inputs (`build.sh`, `*.list`, `rules/*.yaml`, `rules/*.list`,
  scripts, the workflow itself) and manually. mihomo is pinned and verified by
  sha256; actions are pinned by commit SHA (Dependabot keeps them fresh).
  Optional Telegram alert on a red run: set repository secrets
  `TG_ALERT_BOT_TOKEN` and `TG_ALERT_CHAT_ID`.
- **svg-to-png.yml** — on SVG changes: one PNG per SVG (fits 128×128, aspect
  ratio kept) under `icon/png/`; a PNG whose SVG was deleted is removed, so do
  not put PNG-only icons into `icon/png/`.
- Each workflow runs one job at a time (queued runs are kept, not replaced); a push
  rejected because the other workflow committed first is rebased and retried.

## Use in Mihomo

```yaml
rule-providers:
  music:
    type: http
    behavior: domain
    format: mrs
    url: https://raw.githubusercontent.com/<owner>/<repo>/main/rules/music.mrs
    path: ./rule-sets/music.mrs
    interval: 86400
rules:
  - RULE-SET,music,<your-group>
```

For an ipcidr set use `behavior: ipcidr` and add `no-resolve` to the rule:
`- RULE-SET,geoip-for-ru-v4,DIRECT,no-resolve`.
