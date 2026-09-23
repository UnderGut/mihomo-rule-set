# mihomo-rule-set

Rule-sets for Mihomo (clash-meta): hand-maintained source lists plus
auto-compiled `.mrs`, all kept in a single `rules/` directory.

## Layout

```
├── README.md  .gitignore
├── build.sh            # builder: fetch -> compile .mrs into rules/
├── sources.list        # per-source upstreams (one source -> one .mrs)
├── merge.list          # merge groups (N sources -> one merged .mrs)
├── .github/workflows/  # generate-rules.yml (daily) + svg-to-png.yml
├── rules/              # rule-sets (BOTH hand .yaml and compiled .mrs)
└── icon/               # proxy-group icons (svg + png)
```

`build.sh` only **writes its own `.mrs`** into `rules/` — it never deletes the
hand-maintained `.yaml`. Sources and compiled outputs live side by side.

| File kind | behavior | maintained by |
|---|---|---|
| `rules/*.yaml` | classical | by hand (committed manually) |
| `rules/*.mrs`  | domain    | CI (`build.sh`, daily) |

## Build locally

```bash
bash ./build.sh      # needs the `mihomo` binary on PATH (convert-ruleset)
```

## Add a per-source rule (one upstream -> one .mrs)

Append to `sources.list` — `category,url` (the first field is informational;
output is flat `rules/<name>_<type>.mrs`):

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
- type `yaml` = classical `.yaml` (blackmatrix7): `DOMAIN`/`DOMAIN-SUFFIX` kept, rest dropped
- type `locallist` / `localyaml` = the same formats, read from a file in this repo
  (e.g. `tiktok,locallist,rules/tiktok-extra.list` adds hosts missing upstream)
- `exclude_regex` (optional, ERE): matching domains are dropped
- output: `rules/<group>.mrs` (behavior `domain`)

A group is rebuilt only when it is safe; otherwise the previous
`rules/<group>.mrs` is kept and a warning is printed (and annotated on the
GitHub Actions run):

- every source was downloaded and parsed (`curl -f` with retries; empty files,
  HTML error pages and non-domain lines fail the group);
- the new entry count is at least `MERGE_MIN_RATIO`% (default 80) of the
  previous build;
- no entry is a TLD or a public suffix according to the
  [Public Suffix List](https://publicsuffix.org/): ICANN suffixes (`+.com`,
  `+.co.uk`) are rejected in every group, PRIVATE ones (`+.github.io`,
  `+.akamaized.net`) only in `PSL_STRICT_GROUPS` (default `tiktok`).

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
