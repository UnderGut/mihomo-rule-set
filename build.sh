#!/bin/bash
set -e

OUTPUT_DIR="dist"
SOURCES_FILE="sources.list"
TEMP_DIR="temp_work"

echo "--- Cleaning up old files ---"
rm -rf "$OUTPUT_DIR"
mkdir -p "$OUTPUT_DIR"
rm -rf "$TEMP_DIR"
mkdir -p "$TEMP_DIR"

if [ ! -f "$SOURCES_FILE" ]; then
    echo "Error: Sources file not found at '$SOURCES_FILE'!"
    exit 1
fi

# Проверка, является ли строка IP/CIDR
is_ipcidr() {
    local line="$1"
    [[ $line =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}(/[0-9]{1,2})?$ ]]
}

# Функция для определения типа правил внутри .mrs файла
detect_mrs_type() {
    local mrs_file="$1"

    # Проверяем, содержит ли файл ключ "domain" или "ipcidr"
    # Простой поиск ключей в YAML
    if grep -q "domain:" "$mrs_file"; then
        echo "domain"
    elif grep -q "ipcidr:" "$mrs_file"; then
        echo "ipcidr"
    else
        # Если не понятно, возвращаем unknown
        echo "unknown"
    fi
}

# Функция обработки обычного текстового файла (разделение на IP и domain)
process_plain_file() {
    local filepath="$1"
    local rule_name="$2"

    local ip_file="$TEMP_DIR/${rule_name}_ip.txt"
    local domain_file="$TEMP_DIR/${rule_name}_domain.txt"

    > "$ip_file"
    > "$domain_file"

    while IFS= read -r line; do
        [[ -z "$line" || "$line" =~ ^[#\!].* ]] && continue
        if is_ipcidr "$line"; then
            echo "$line" >> "$ip_file"
        else
            echo "$line" >> "$domain_file"
        fi
    done < "$filepath"

    if [ -s "$ip_file" ]; then
        echo "Converting IP list for $rule_name"
        mihomo convert-ruleset ipcidr text "$ip_file" "$OUTPUT_DIR/${rule_name}_ip.mrs"
        echo "✅ $rule_name IP converted."
    fi

    if [ -s "$domain_file" ]; then
        echo "Converting domain list for $rule_name"
        local temp_yaml="$TEMP_DIR/${rule_name}_domain.yaml"
        echo "payload:" > "$temp_yaml"
        grep -v -E '^(#|$|!)' "$domain_file" | sed "s/.*/  - '&'/" >> "$temp_yaml"
        mihomo convert-ruleset domain yaml "$temp_yaml" "$OUTPUT_DIR/${rule_name}_domain.mrs"
        echo "✅ $rule_name domain converted."
    fi
}

echo "--- Starting build process ---"
while IFS= read -r line; do
    [[ -z "$line" || "$line" == \#* ]] && continue

    url="$line"
    source_filename=$(basename "$url")
    rule_name="${source_filename%.*}"

    echo "Processing: $rule_name from $url"
    curl -L -s -o "$TEMP_DIR/$source_filename" "$url"

    ext="${source_filename##*.}"

    if [[ "$ext" == "mrs" ]]; then
        # Определяем тип правил внутри .mrs
        mrs_type=$(detect_mrs_type "$TEMP_DIR/$source_filename")
        echo "Detected .mrs type: $mrs_type"

        # Переименовываем или копируем с добавлением типа в имя
        cp "$TEMP_DIR/$source_filename" "$OUTPUT_DIR/${rule_name}_${mrs_type}.mrs"

    else
        # Обрабатываем как обычный текстовый список с авторазделением
        process_plain_file "$TEMP_DIR/$source_filename" "$rule_name"
    fi

    echo "-------------------------------------"
done < "$SOURCES_FILE"

echo "--- Cleaning up temporary files ---"
rm -rf "$TEMP_DIR"

echo "🎉 Build process finished successfully."
