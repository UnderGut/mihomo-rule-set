#!/usr/bin/env bash
# Lint hand-written classical rule files: rules/*.yaml
set -euo pipefail
TYPES='DOMAIN|DOMAIN-SUFFIX|DOMAIN-KEYWORD|DOMAIN-REGEX|DOMAIN-WILDCARD|GEOSITE|GEOIP|IP-CIDR|IP-CIDR6|IP-SUFFIX|IP-ASN|SRC-IP-CIDR|SRC-IP-SUFFIX|SRC-IP-ASN|SRC-GEOIP|DST-PORT|SRC-PORT|IN-PORT|IN-TYPE|IN-USER|IN-NAME|NETWORK|UID|DSCP|PROCESS-NAME|PROCESS-NAME-REGEX|PROCESS-PATH|PROCESS-PATH-REGEX|AND|OR|NOT'
rc=0
for f in rules/*.yaml; do
  out=$(awk -v types="$TYPES" '
    /^[[:space:]]*(#|$)/ { next }
    NR == 1 || !seen { if ($0 ~ /^payload:[[:space:]]*$/) { seen = 1; next } }
    /\t/ { print FILENAME ":" FNR ": tab character"; next }
    {
      line = $0
      if (line !~ /^  - /) { print FILENAME ":" FNR ": not a \"  - \" list item: " line; next }
      sub(/^  - /, "", line); sub(/[[:space:]]+#.*$/, "", line); gsub(/^'\''|'\''$/, "", line)
      split(line, a, ","); if (a[1] !~ ("^(" types ")$") || a[2] == "") print FILENAME ":" FNR ": bad rule: " line
    }
    END { if (!seen) print FILENAME ": no payload: key" }' "$f")
  if [[ -n "$out" ]]; then rc=1; while IFS= read -r l; do echo "::error::$l"; done <<< "$out"; else echo "ok: $f ($(grep -cE '^  - ' "$f") rules)"; fi
done
exit "$rc"
