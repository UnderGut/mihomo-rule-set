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

# Функция для проверки, является ли строка IP или CIDR
is_ipcidr() {
    local line="$1"
    # Простой regex для IPv4, с необязательным маском
    if [[ $line =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}(/[0-9]{1,2})?$ ]]; then
        return 0
    fi
    return 1
}

# Функция для конвертации файлов с возможным разделением
process_file() {
    local filepath="$1"
    local rule_name="$2"

    # Файлы для разделения
    local ip_file="$TEMP_DIR/${rule_name}_ip.txt"
    local domain_file="$TEMP_DIR/${rule_name}_domain.txt"

    # Очищаем файлы
    > "$ip_file"
    > "$domain_file"

    # Разделяем строки по типу
    while IFS= read -r line; do
        # Пропускаем комментарии и пустые строки
        [[ -z "$line" || "$line" =~ ^[#\!].* ]] && continue

        if is_ipcidr "$line"; then
            echo "$line" >> "$ip_file"
        else
            echo "$line" >> "$domain_file"
        fi
    done < "$filepath"

    # Конвертируем IP список, если он не пустой
    if [ -s "$ip_file" ]; then
        echo "Converting IP list for $rule_name"
        mihomo convert-ruleset ipcidr text "$ip_file" "$OUTPUT_DIR/${rule_name}_ip.mrs"
        echo "✅ Converted IP list to $OUTPUT_DIR/${rule_name}_ip.mrs"
    fi

    # Конвертируем domain список, если он не пустой
    if [ -s "$domain_file" ]; then
        echo "Converting domain list for $rule_name"
        local temp_yaml="$TEMP_DIR/${rule_name}_domain.yaml"
        echo "payload:" > "$temp_yaml"
        grep -v -E '^(#|$|!)' "$domain_file" | sed "s/.*/  - '&'/" >> "$temp_yaml"
        mihomo convert-ruleset domain yaml "$temp_yaml" "$OUTPUT_DIR/${rule_name}_domain.mrs"
        echo "✅ Converted domain list to $OUTPUT_DIR/${rule_name}_domain.mrs"
    fi
}

echo "--- Starting build process ---"
while IFS= read -r line; do
    # Пропускаем пустые и комментарии
    [[ -z "$line" || "$line" == \#* ]] && continue

    # Разбираем строку: ожидаем URL (без типа — автоопределение)
    url="$line"
    source_filename=$(basename "$url")
    rule_name="${source_filename%.*}"

    echo "Processing rule: $rule_name"
    echo "Downloading $url ..."
    curl -L -s -o "$TEMP_DIR/$source_filename" "$url"

    # Вызываем функцию обработки с автоопределением
    process_file "$TEMP_DIR/$source_filename" "$rule_name"

    echo "-------------------------------------"

done < "$SOURCES_FILE"

echo "--- Cleaning up temporary files ---"
rm -rf "$TEMP_DIR"

echo "🎉 Build process finished successfully."
