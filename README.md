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
- `exclude_regex` (optional, ERE): matching domains are dropped
- output: `rules/<group>.mrs` (behavior `domain`)

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
