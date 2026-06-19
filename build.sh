#!/bin/bash
set -e

# --- КОНФИГУРАЦИЯ ---
OUTPUT_DIR="dist"
SOURCES_FILE="sources.list"
TEMP_DIR="temp_work"

# --- ПОДГОТОВКА ---
echo "--- Cleaning up old files ---"
rm -rf "$OUTPUT_DIR"
mkdir -p "$OUTPUT_DIR"
rm -rf "$TEMP_DIR"
mkdir -p "$TEMP_DIR"

if [[ ! -f "$SOURCES_FILE" ]]; then
    echo "❌ Error: Sources file not found at '$SOURCES_FILE'!"
    exit 1
fi

# --- ВСПОМОГАТЕЛЬНЫЕ ФУНКЦИИ ---

is_ipcidr() {
    [[ $1 =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}(/[0-9]{1,2})?$ ]]
}

detect_mrs_type() {
    local file="$1"
    local has_domain=0 has_ipcidr=0 has_process=0

    grep -q "domain:" "$file" && has_domain=1
    grep -q "ipcidr:" "$file" && has_ipcidr=1
    grep -q '^[[:space:]]*- PROCESS-NAME,' "$file" && has_process=1
    grep -q '^[[:space:]]*-\ DOMAIN-' "$file" && has_domain=1

    local count=$((has_domain + has_ipcidr + has_process))

    if [ $count -gt 1 ]; then echo "mixed"
    elif [ $count -eq 1 ]; then
        [ $has_domain -eq 1 ] && echo "domain"
        [ $has_ipcidr -eq 1 ] && echo "ipcidr"
        [ $has_process -eq 1 ] && echo "process-name"
    else
        echo "domain"
    fi
}

# Обработка .conf файлов
process_conf_file() {
    local filepath="$1"
    local rule_name="$2"
    local outdir="$3"

    local yaml_file="$TEMP_DIR/${rule_name}_from_conf.yaml"
    echo "payload:" > "$yaml_file"

    while IFS= read -r line; do
        [[ -z "$line" || "$line" == \#* ]] && continue
        echo "  - DOMAIN-SUFFIX,${line#,}" >> "$yaml_file"
    done < "$filepath"

    mkdir -p "$outdir"
    mihomo convert-ruleset domain yaml "$yaml_file" "$outdir/${rule_name}_domain.mrs"
    echo "  ✅ $rule_name conf list converted."
}

# Обработка обычных текстовых файлов
process_plain_file() {
    local filepath="$1"
    local rule_name="$2"
    local outdir="$3"

    local ip_file="$TEMP_DIR/${rule_name}_ip.txt"
    local domain_file="$TEMP_DIR/${rule_name}_domain.txt"
    local process_file="$TEMP_DIR/${rule_name}_process.txt"

    > "$ip_file"; > "$domain_file"; > "$process_file"

    while IFS= read -r line; do
        [[ -z "$line" || "$line" =~ ^[#\!].* ]] && continue
        if [[ "$line" =~ ^PROCESS-NAME, ]]; then
            echo "$line" >> "$process_file"
        elif is_ipcidr "$line"; then
            echo "$line" >> "$ip_file"
        else
            echo "$line" >> "$domain_file"
        fi
    done < "$filepath"

    mkdir -p "$outdir"

    if [ -s "$ip_file" ]; then
        mihomo convert-ruleset ipcidr text "$ip_file" "$outdir/${rule_name}_ip.mrs"
        echo "  ✅ $rule_name IP list converted."
    fi

    if [ -s "$domain_file" ]; then
        local temp_yaml="$TEMP_DIR/${rule_name}_domain.yaml"
        echo "payload:" > "$temp_yaml"
        sed "s/.*/  - '&'/" "$domain_file" >> "$temp_yaml"
        mihomo convert-ruleset domain yaml "$temp_yaml" "$outdir/${rule_name}_domain.mrs"
        echo "  ✅ $rule_name domain list converted."
    fi

    if [ -s "$process_file" ]; then
        local temp_yaml="$TEMP_DIR/${rule_name}_process.yaml"
        echo "payload:" > "$temp_yaml"
        sed 's/^PROCESS-NAME,//' "$process_file" | sed "s/.*/  - PROCESS-NAME,&/" >> "$temp_yaml"
        mihomo convert-ruleset logical yaml "$temp_yaml" "$outdir/${rule_name}_process.mrs"
        echo "  ✅ $rule_name process-name list converted."
    fi
}

# --- ОСНОВНОЙ ЦИКЛ ---

echo "--- Starting build process ---"

while IFS= read -r line; do
    [[ -z "$line" || "$line" == \#* ]] && continue

    folder=""
    url="$line"

    if [[ "$line" == *,* ]]; then
        folder="$(echo "$line" | cut -d',' -f1 | xargs)"
        url="$(echo "$line" | cut -d',' -f2- | xargs)"
    fi

    source_filename=$(basename "$url")
    rule_name="${source_filename%.*}"
    outdir="$OUTPUT_DIR"
    [[ -n "$folder" ]] && outdir="$OUTPUT_DIR/$folder"

    echo "Processing: $rule_name"
    echo "  -> Saving to: $outdir"

    curl -L -s -o "$TEMP_DIR/$source_filename" "$url"
    ext="${source_filename##*.}"

    if [[ "$ext" == "conf" ]]; then
        process_conf_file "$TEMP_DIR/$source_filename" "$rule_name" "$outdir"
    elif [[ "$ext" == "mrs" || "$ext" == "yaml" ]]; then
        mrs_type=$(detect_mrs_type "$TEMP_DIR/$source_filename")
        mkdir -p "$outdir"
        cp "$TEMP_DIR/$source_filename" "$outdir/${rule_name}_${mrs_type}.mrs"
        echo "  ✅ Saved as ${rule_name}_${mrs_type}.mrs"
    else
        process_plain_file "$TEMP_DIR/$source_filename" "$rule_name" "$outdir"
    fi

    echo "-------------------------------------"
done < "$SOURCES_FILE"

# --- MERGE GROUPS (consolidate N sources -> one .mrs) ---
# Config: merge.list, lines "group,type,url[,exclude_regex]"
#   type = list  (plain domain list, e.g. MetaCubeX *.list)
#        | yaml  (classical *.yaml, e.g. blackmatrix7: DOMAIN/DOMAIN-SUFFIX kept)
#   exclude_regex = optional ERE; matching domains are dropped (e.g. typosquats)
# Output: dist/<group>.mrs (+ dist/<group>.list). Best-effort: never breaks the
# core build above (failures are logged, not fatal).
MERGE_FILE="merge.list"
if [[ -f "$MERGE_FILE" ]]; then
    echo "--- Processing merge groups ---"
    groups=$(grep -vE '^[[:space:]]*(#|$)' "$MERGE_FILE" | cut -d',' -f1 | sort -u || true)
    for grp in $groups; do
        echo "Merging group: $grp"
        combined="$TEMP_DIR/${grp}_combined.txt"; > "$combined"
        while IFS= read -r mline; do
            [[ -z "$mline" || "$mline" == \#* ]] && continue
            g="$(echo "$mline" | cut -d',' -f1 | xargs)"
            [[ "$g" != "$grp" ]] && continue
            mtype="$(echo "$mline" | cut -d',' -f2 | xargs)"
            murl="$(echo "$mline" | cut -d',' -f3 | xargs)"
            mexclude="$(echo "$mline" | cut -d',' -f4-)"
            tmpf="$TEMP_DIR/merge_$(basename "$murl")"
            curl -L -s -o "$tmpf" "$murl" || true
            [[ ! -s "$tmpf" ]] && { echo "  ⚠ empty/failed: $murl"; continue; }
            extracted="$TEMP_DIR/merge_extract.txt"
            if [[ "$mtype" == "yaml" ]]; then
                awk '
                  { line=$0; sub(/^[[:space:]]*-?[[:space:]]*/,"",line) }
                  line ~ /^DOMAIN-SUFFIX,/ { split(line,a,","); d=a[2]; gsub(/[[:space:]]/,"",d); if(d!="") print "+." d; next }
                  line ~ /^DOMAIN,/        { split(line,a,","); d=a[2]; gsub(/[[:space:]]/,"",d); if(d!="") print d; next }
                ' "$tmpf" > "$extracted" || true
            else
                awk 'NF && $0 !~ /^[[:space:]]*#/ { gsub(/[[:space:]]/,""); if($0!="") print }' "$tmpf" > "$extracted" || true
            fi
            if [[ -n "$mexclude" ]]; then
                grep -vE "$mexclude" "$extracted" >> "$combined" || true
            else
                cat "$extracted" >> "$combined" || true
            fi
        done < "$MERGE_FILE"
        sorted="$TEMP_DIR/${grp}_sorted.txt"
        sort -u "$combined" | grep -E '\.' > "$sorted" || true
        count=$(wc -l < "$sorted" | tr -d '[:space:]')
        if [ "${count:-0}" -gt 0 ]; then
            yaml="$TEMP_DIR/${grp}_payload.yaml"
            echo "payload:" > "$yaml"
            sed "s/.*/  - '&'/" "$sorted" >> "$yaml"
            mkdir -p "$OUTPUT_DIR"
            if mihomo convert-ruleset domain yaml "$yaml" "$OUTPUT_DIR/${grp}.mrs"; then
                cp "$sorted" "$OUTPUT_DIR/${grp}.list"
                echo "  ✅ $grp merged: $count domains -> $OUTPUT_DIR/${grp}.mrs"
            else
                echo "  ⚠ $grp compile failed (kept previous .mrs)"
            fi
        else
            echo "  ⚠ $grp produced 0 domains, skipped"
        fi
        echo "-------------------------------------"
    done
fi

echo "--- Cleaning up temporary files ---"
rm -rf "$TEMP_DIR"
echo "🎉 Build process finished successfully."
