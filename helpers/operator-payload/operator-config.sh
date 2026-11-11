#!/usr/bin/bash

declare -A OPERATOR_CONFIGS

parse_config() {
    local config_file="$1"
    local section="" key value

    while IFS='=' read -r key value || [[ -n "$key" ]]; do
        [[ "$key" =~ ^[[:space:]]*# || -z "$key" ]] && continue

        if [[ "$key" =~ ^\[([^]]+)\] ]]; then
            section="${BASH_REMATCH[1]}"
        elif [[ -n "$section" ]]; then
            key=$(echo "$key" | xargs)
            value=$(echo "$value" | xargs)
            OPERATOR_CONFIGS["${section}.${key}"]="$value"
        fi
    done < "$config_file"
}

get_config() {
    printf '%s\n' "${OPERATOR_CONFIGS[$1.$2]:-${3:-}}"
}
