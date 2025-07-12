#!/bin/bash

set -e

OUTPUT_DIR="dist"
SOURCES_FILE="sources.list"
TEMP_DIR="temp_work"

echo "--- Cleaning up old files ---"
rm -rf "$OUTPUT_DIR" "$TEMP_DIR"
mkdir -p "$OUTPUT_DIR" "$TEMP_DIR"

if [ ! -f "$SOURCES_FILE" ]; then
    echo "Error: Sources file '$SOURCES_FILE' not found!"
    exit 1
fi

while IFS= read -r line; do
    # Пропускаем пустые строки и комментарии
    [[ -z "$line" || "$line" =~ ^# ]] && continue

    # Формат: ruletype,url — но ruletype может быть пустым или "-"
    IFS=',' read -r ruletype url <<< "$line"
    url=$(echo "$url" | xargs) # убрать пробелы

    source_filename=$(basename "$url")
    rule_name="${source_filename%.*}"
    extension="${source_filename##*.}"

    echo "Processing: $source_filename (declared type: '$ruletype')"

    # Скачиваем файл
    curl -L -s -o "$TEMP_DIR/$source_filename" "$url"

    if [[ "$extension" == "mrs" ]]; then
        # Определяем тип из содержимого .mrs
        detected_type=$(grep '^type:' "$TEMP_DIR/$source_filename" | head -1 | awk '{print $2}')
        echo "Detected type inside .mrs: $detected_type"
        # Можно переопределить ruletype из .mrs
        ruletype="$detected_type"

        # Просто копируем .mrs в dist/
        cp "$TEMP_DIR/$source_filename" "$OUTPUT_DIR/$rule_name.mrs"
        echo "Copied .mrs file to $OUTPUT_DIR/$rule_name.mrs"

    else
        # Обработка для domain и ipcidr и др.
        if [[ "$ruletype" == "ipcidr" ]]; then
            mihomo convert-ruleset ipcidr text "$TEMP_DIR/$source_filename" "$OUTPUT_DIR/$rule_name.mrs"
            echo "✅ Converted IP list to $OUTPUT_DIR/$rule_name.mrs"

        elif [[ "$ruletype" == "domain" ]]; then
            temp_yaml="$TEMP_DIR/$rule_name.yaml"
            echo "payload:" > "$temp_yaml"
            grep -v -E '^(#|$|!)' "$TEMP_DIR/$source_filename" | sed "s/.*/  - '&'/" >> "$temp_yaml"
            mihomo convert-ruleset domain yaml "$temp_yaml" "$OUTPUT_DIR/$rule_name.mrs"
            echo "✅ Converted domain list to $OUTPUT_DIR/$rule_name.mrs"

        else
            echo "⚠️ WARNING: Unknown rule type '$ruletype' for $url. Skipping."
        fi
    fi

    echo "-------------------------------------"

done < "$SOURCES_FILE"

echo "--- Cleaning up temporary files ---"
rm -rf "$TEMP_DIR"

echo "🎉 Build finished successfully."
