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

# Определение типа внутри .mrs файла с учетом PROCESS-NAME
detect_mrs_type() {
    local mrs_file="$1"

    # Ищем признаки каждого типа
    local has_domain=0
    local has_ipcidr=0
    local has_process=0

    # Есть ли domain
    if grep -q "domain:" "$mrs_file"; then
        has_domain=1
    fi

    # Есть ли ipcidr
    if grep -q "ipcidr:" "$mrs_file"; then
        has_ipcidr=1
    fi

    # Есть ли PROCESS-NAME в payload
    if grep -q '^  - PROCESS-NAME,' "$mrs_file"; then
        has_process=1
    fi

    # Если найден только один тип — возвращаем его
    local count=$((has_domain + has_ipcidr + has_process))

    if [ $count -eq 1 ]; then
        if [ $has_domain -eq 1 ]; then
            echo "domain"
            return
        elif [ $has_ipcidr -eq 1 ]; then
            echo "ipcidr"
            return
        else
            echo "process-name"
            return
        fi
    fi

    # Если смешанные типы, возвращаем "mixed"
    if [ $count -gt 1 ]; then
        echo "mixed"
        return
    fi

    # Если ни один не найден, пустой результат
    echo ""
}

# Обработка простых текстовых файлов (ip + domain)
process_plain_file() {
    local filepath="$1"
    local rule_name="$2"
    local subdir="$3"

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

    # Создаем целевую папку, если нужно
    mkdir -p "$OUTPUT_DIR/$subdir"

    if [ -s "$ip_file" ]; then
        echo "Converting IP list for $rule_name"
        mihomo convert-ruleset ipcidr text "$ip_file" "$OUTPUT_DIR/$subdir/${rule_name}_ip.mrs"
        echo "✅ $rule_name IP converted."
    fi

    if [ -s "$domain_file" ]; then
        echo "Converting domain list for $rule_name"
        local temp_yaml="$TEMP_DIR/${rule_name}_domain.yaml"
        echo "payload:" > "$temp_yaml"
        grep -v -E '^(#|$|!)' "$domain_file" | sed "s/.*/  - '&'/" >> "$temp_yaml"
        mihomo convert-ruleset domain yaml "$temp_yaml" "$OUTPUT_DIR/$subdir/${rule_name}_domain.mrs"
        echo "✅ $rule_name domain converted."
    fi
}

# Функция сохранения файла .mrs с учетом типа и поддиректорий
save_mrs_with_type() {
    local src="$1"
    local base_name="$2"
    local type="$3"
    local subdir="$4"

    # Если тип пустой (неопределенный), не сохраняем
    if [[ -z "$type" ]]; then
        echo "⚠️ Type unknown, skipping saving $base_name.mrs"
        return
    fi

    mkdir -p "$OUTPUT_DIR/$subdir"
    cp "$src" "$OUTPUT_DIR/$subdir/${base_name}_${type}.mrs"
    echo "Saved $base_name as ${base_name}_${type}.mrs in $subdir"
}

echo "--- Starting build process ---"

while IFS= read -r line; do
    [[ -z "$line" || "$line" == \#* ]] && continue

    url="$line"
    # Извлекаем путь после домена и до имени файла, для подпапок
    # Пример: https://github.com/UnderGut/rule-set/raw/main/clash/ru-inline.yaml
    # Возьмем path после "raw/" или после "main/"
    # Для универсальности извлечем всё после "github.com/*/*/raw/" или "github.com/*/*/blob/"
    # Поскольку raw имеет структуру: ...github.com/user/repo/raw/branch/...
    # Используем grep + cut или parameter expansion

    # Удаляем протокол и домен
    path_without_protocol="${url#*://*/}"
    # Лучше использовать более надежно:
    # Для github raw ссылки вырежем всё после "github.com/user/repo/raw/branch/"
    # Пример, URL = https://github.com/UnderGut/rule-set/raw/main/clash/ru-inline.yaml
    # Тогда хотим получить "clash" и дальше путь к файлу

    # Используем для этого регулярку с grep -Po
if [[ "$url" =~ github.com/.+/.+/(raw|blob)/.+/.+ ]]; then
    tmp="${url#*github.com/}"
    tmp="${tmp#*/}"
    tmp="${tmp#*/}"
    tmp="${tmp#raw/}"
    tmp="${tmp#blob/}"
    tmp="${tmp#*/}"
    path_part="$tmp"
else
    path_part=""
fi

    # Теперь путь будет что-то вроде "clash/ru-inline.yaml"

    # Отделяем имя файла
    source_filename=$(basename "$url")
    rule_name="${source_filename%.*}"

    # Отделяем подпапку (все пути кроме файла)
    subdir=$(dirname "$path_part")

    echo "Processing: $rule_name from $url"
    echo "Target subdirectory: $subdir"

    curl -L -s -o "$TEMP_DIR/$source_filename" "$url"

    ext="${source_filename##*.}"

    if [[ "$ext" == "mrs" ]]; then
        mrs_type=$(detect_mrs_type "$TEMP_DIR/$source_filename")
        echo "Detected .mrs type: $mrs_type"

        # Если mixed — просто сохраняем с этим суффиксом
        if [[ "$mrs_type" == "mixed" ]]; then
            mkdir -p "$OUTPUT_DIR/$subdir"
            cp "$TEMP_DIR/$source_filename" "$OUTPUT_DIR/$subdir/${rule_name}_mixed.mrs"
            echo "Saved mixed type file"
        elif [[ -n "$mrs_type" ]]; then
            save_mrs_with_type "$TEMP_DIR/$source_filename" "$rule_name" "$mrs_type" "$subdir"
        else
            echo "⚠️ Unknown .mrs file type for $rule_name, skipping save"
        fi

    else
        # Обычный текстовый файл
        process_plain_file "$TEMP_DIR/$source_filename" "$rule_name" "$subdir"
    fi

    echo "-------------------------------------"
done < "$SOURCES_FILE"

echo "--- Cleaning up temporary files ---"
rm -rf "$TEMP_DIR"

echo "🎉 Build process finished successfully."
