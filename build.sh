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

# --- ОБРАБОТКА ---

echo "--- Starting build process ---"

while IFS= read -r line; do
    [[ -z "$line" || "$line" == \#* ]] && continue

    folder=""
    url="$line"

    # Если строка содержит запятую
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

    if [[ "$ext" == "mrs" || "$ext" == "yaml" ]]; then
        mrs_type=$(detect_mrs_type "$TEMP_DIR/$source_filename")
        mkdir -p "$outdir"
        cp "$TEMP_DIR/$source_filename" "$outdir/${rule_name}_${mrs_type}.mrs"
        echo "  ✅ Saved as ${rule_name}_${mrs_type}.mrs"
    else
        process_plain_file "$TEMP_DIR/$source_filename" "$rule_name" "$outdir"
    fi

    echo "-------------------------------------"
done < "$SOURCES_FILE"

echo "--- Cleaning up temporary files ---"
rm -rf "$TEMP_DIR"
echo "🎉 Build process finished successfully."
