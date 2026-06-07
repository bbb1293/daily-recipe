#!/bin/zsh
set -euo pipefail

KITCHEN_DIR="${0:A:h}"
DATA_DIR="${KITCHEN_DATA_DIR:-$KITCHEN_DIR}"
INGREDIENTS_FILE="$DATA_DIR/ingredients.txt"
PANTRY_FILE="$DATA_DIR/pantry.txt"

usage() {
  cat <<'EOF'
Usage: kitchen <command> [args]

Manage the ingredients and pantry lists used by the recipe generator.

Commands:
  list [ingredients|pantry]              Show a list (default: both)
  add <ingredients|pantry> <item>... [--urgent]
                                         Add items (--urgent: ingredients only)
  remove <ingredients|pantry> <item>...  Remove items
  urgent <item>...                       Mark ingredients as urgent
  unurgent <item>...                     Clear urgent from ingredients
  -h, --help                             Show this help

Items are matched case-insensitively and exactly. Multi-word items must be
quoted, e.g. kitchen add ingredients "chicken thighs".
EOF
}

die_usage() { echo "$1" >&2; exit 2; }

file_for_list() {
  case "$1" in
    ingredients) echo "$INGREDIENTS_FILE" ;;
    pantry) echo "$PANTRY_FILE" ;;
    *) return 1 ;;
  esac
}

resolved_file() {
  local file="$1"
  if [[ -e "$file" ]]; then
    echo "${file:A}"
  else
    echo "$file"
  fi
}

norm_key() {
  local s
  s=$(printf '%s' "$1" | sed -E 's/[[:space:]]*!urgent[[:space:]]*$//; s/^[[:space:]]+//; s/[[:space:]]+$//')
  printf '%s' "${(L)s}"
}

disp() {
  printf '%s' "$1" | sed -E 's/[[:space:]]*!urgent[[:space:]]*$//; s/^[[:space:]]+//; s/[[:space:]]+$//'
}

is_skip() {
  [[ "$1" =~ '^[[:space:]]*#' ]] && return 0
  [[ -z "${1//[[:space:]]/}" ]] && return 0
  return 1
}

print_list() {
  local list="$1" file any=false line
  file=$(resolved_file "$(file_for_list "$list")")
  echo "== $list =="
  if [[ -f "$file" ]]; then
    while IFS= read -r line || [[ -n "$line" ]]; do
      is_skip "$line" && continue
      any=true
      if [[ "$line" == *'!urgent'* ]]; then
        echo "$(disp "$line") ⚠ urgent"
      else
        echo "$(disp "$line")"
      fi
    done < "$file"
  fi
  [[ "$any" == true ]] || echo "(none)"
}

cmd_list() {
  if [[ $# -eq 0 ]]; then
    print_list ingredients
    echo
    print_list pantry
    return
  fi
  file_for_list "$1" >/dev/null 2>&1 || die_usage "list: unknown list '$1' (use ingredients or pantry)"
  print_list "$1"
}

list_contains() {
  local file="$1" key="$2" line
  file=$(resolved_file "$file")
  [[ -f "$file" ]] || return 1
  while IFS= read -r line || [[ -n "$line" ]]; do
    is_skip "$line" && continue
    [[ "$(norm_key "$line")" == "$key" ]] && return 0
  done < "$file"
  return 1
}

cmd_add() {
  local list="${1:-}"
  [[ -n "$list" ]] || die_usage "add: missing list (ingredients or pantry)"
  shift
  local file
  file=$(file_for_list "$list") || die_usage "add: unknown list '$list' (use ingredients or pantry)"
  file=$(resolved_file "$file")
  local urgent=false items=() arg
  for arg in "$@"; do
    if [[ "$arg" == "--urgent" ]]; then urgent=true; else items+=("$arg"); fi
  done
  (( ${#items[@]} > 0 )) || die_usage "add: provide at least one item"
  if [[ "$urgent" == true && "$list" != "ingredients" ]]; then
    die_usage "add: --urgent is only valid for the ingredients list"
  fi
  [[ -f "$file" ]] || : > "$file"
  local item name
  for item in "${items[@]}"; do
    name=$(disp "$item")
    if list_contains "$file" "$(norm_key "$item")"; then
      echo "Already in $list: $name"
    elif [[ "$urgent" == true ]]; then
      printf '%s !urgent\n' "$name" >> "$file"
      echo "Added to $list: $name"
    else
      printf '%s\n' "$name" >> "$file"
      echo "Added to $list: $name"
    fi
  done
}

rewrite_without() {
  local file="$1" key="$2" tmp removed=false line
  file=$(resolved_file "$file")
  [[ -f "$file" ]] || return 1
  tmp=$(mktemp "${file:h}/.kitchen.XXXXXX")
  while IFS= read -r line || [[ -n "$line" ]]; do
    if is_skip "$line"; then printf '%s\n' "$line" >> "$tmp"; continue; fi
    if [[ "$(norm_key "$line")" == "$key" ]]; then removed=true; continue; fi
    printf '%s\n' "$line" >> "$tmp"
  done < "$file"
  mv "$tmp" "$file"
  [[ "$removed" == true ]]
}

cmd_remove() {
  local list="${1:-}"
  [[ -n "$list" ]] || die_usage "remove: missing list (ingredients or pantry)"
  shift
  local file
  file=$(file_for_list "$list") || die_usage "remove: unknown list '$list' (use ingredients or pantry)"
  (( $# > 0 )) || die_usage "remove: provide at least one item"
  local item
  for item in "$@"; do
    if rewrite_without "$file" "$(norm_key "$item")"; then
      echo "Removed from $list: $(disp "$item")"
    else
      echo "Not found in $list: $(disp "$item")"
    fi
  done
}

apply_urgent() {
  local file="$1" key="$2" mode="$3" tmp found=false line base
  file=$(resolved_file "$file")
  [[ -f "$file" ]] || { echo notfound; return 0; }
  tmp=$(mktemp "${file:h}/.kitchen.XXXXXX")
  while IFS= read -r line || [[ -n "$line" ]]; do
    if is_skip "$line"; then printf '%s\n' "$line" >> "$tmp"; continue; fi
    if [[ "$(norm_key "$line")" == "$key" ]]; then
      found=true
      base=$(disp "$line")
      if [[ "$mode" == "add" ]]; then
        printf '%s !urgent\n' "$base" >> "$tmp"
      else
        printf '%s\n' "$base" >> "$tmp"
      fi
    else
      printf '%s\n' "$line" >> "$tmp"
    fi
  done < "$file"
  mv "$tmp" "$file"
  [[ "$found" == true ]] && echo found || echo notfound
}

set_urgent() {
  local mode="$1"; shift
  local label word
  if [[ "$mode" == "add" ]]; then label="Marked urgent"; word="urgent"
  else label="Cleared urgent"; word="unurgent"; fi
  (( $# > 0 )) || die_usage "$word: provide at least one item"
  local item
  for item in "$@"; do
    if [[ "$(apply_urgent "$INGREDIENTS_FILE" "$(norm_key "$item")" "$mode")" == "found" ]]; then
      echo "$label: $(disp "$item")"
    else
      echo "Not found in ingredients: $(disp "$item")"
    fi
  done
}

cmd_urgent() { set_urgent add "$@"; }
cmd_unurgent() { set_urgent remove "$@"; }

cmd="${1:-}"
shift 2>/dev/null || true
case "$cmd" in
  list) cmd_list "$@" ;;
  add) cmd_add "$@" ;;
  remove) cmd_remove "$@" ;;
  urgent) cmd_urgent "$@" ;;
  unurgent) cmd_unurgent "$@" ;;
  -h|--help) usage; exit 0 ;;
  "") usage >&2; exit 2 ;;
  *) die_usage "unknown command: $cmd (try list, add, remove, urgent, unurgent)" ;;
esac
