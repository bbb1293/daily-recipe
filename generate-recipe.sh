#!/bin/zsh
set -euo pipefail

# Resolve the real directory of this script (following symlinks),
# so the tool works regardless of where it's cloned.
FOOD_DIR="${0:A:h}"
INGREDIENTS_FILE="$FOOD_DIR/ingredients.txt"
PANTRY_FILE="$FOOD_DIR/pantry.txt"
RECIPES_DIR="$FOOD_DIR/recipes"
LOG_FILE="$FOOD_DIR/generate-recipe.log"

export PATH="/Users/mac/.local/bin:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin"

usage() {
  cat <<EOF
Usage: recipe [OPTIONS]

Generates three recipe options for a given day using ingredients.txt and pantry.txt.

Options:
  --today                 Generate for today (default: tomorrow)
  --date YYYY-MM-DD       Generate for a specific date
  --force                 Regenerate even if the target file exists
  --print                 Print the recipe to stdout instead of opening a dialog
  -h, --help              Show this help

When run from a terminal, output prints to stdout by default.
When run headless (e.g. launchd), a dialog pops up with an Open button.
EOF
}

TARGET_DATE=""
FORCE=false
FORCE_PRINT=false
while [[ $# -gt 0 ]]; do
  case "$1" in
    --today) TARGET_DATE=$(date +%Y-%m-%d); shift ;;
    --date) TARGET_DATE="$2"; shift 2 ;;
    --force) FORCE=true; shift ;;
    --print) FORCE_PRINT=true; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Unknown option: $1" >&2; usage >&2; exit 2 ;;
  esac
done

TARGET_DATE="${TARGET_DATE:-$(date -v+1d +%Y-%m-%d)}"
OUTPUT_FILE="$RECIPES_DIR/$TARGET_DATE.md"
HTML_FILE="$RECIPES_DIR/$TARGET_DATE.html"
CSS_FILE="$FOOD_DIR/recipe.css"

if [[ -t 1 ]] || [[ "$FORCE_PRINT" == "true" ]]; then
  INTERACTIVE=true
else
  INTERACTIVE=false
fi

log() {
  echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" >> "$LOG_FILE"
  if [[ "$INTERACTIVE" == "true" ]]; then
    echo "$*" >&2
  fi
}

notify_dialog() {
  local title="$1"
  local message="$2"
  local open_path="${3:-}"

  if [[ -n "$open_path" ]]; then
    local button
    button=$(osascript \
      -e "button returned of (display dialog \"$message\" with title \"$title\" buttons {\"Later\", \"Open\"} default button \"Open\" with icon note)" \
      2>> "$LOG_FILE") || true
    if [[ "$button" == "Open" ]]; then
      open "$open_path" >> "$LOG_FILE" 2>&1 || true
    fi
  else
    osascript \
      -e "display dialog \"$message\" with title \"$title\" buttons {\"OK\"} default button \"OK\" with icon caution" \
      >> "$LOG_FILE" 2>&1 || true
  fi
}

mkdir -p "$RECIPES_DIR"

render_html() {
  local md="$1"
  local html="$2"
  if ! command -v pandoc >/dev/null 2>&1; then
    log "pandoc not installed — skipping HTML render."
    return 1
  fi
  local tmp_html="$html.tmp"
  pandoc --from=gfm --to=html5 --standalone \
    --metadata pagetitle="Recipes for $TARGET_DATE" \
    --css="recipe.css" \
    "$md" -o "$tmp_html" 2>> "$LOG_FILE" || { rm -f "$tmp_html"; return 1; }
  # Highlight MISSING tags by post-processing the generated HTML.
  sed -E 's|<strong>\(MISSING([^<]*)</strong>|<span class="missing">(MISSING\1</span>|g' \
    "$tmp_html" > "$html"
  rm -f "$tmp_html"
  # Ensure the stylesheet sits next to the HTML for browser loading.
  cp -f "$CSS_FILE" "$RECIPES_DIR/recipe.css" 2>> "$LOG_FILE" || true
}

if [[ -f "$OUTPUT_FILE" && "$FORCE" != "true" ]]; then
  log "Recipes for $TARGET_DATE already exist at $OUTPUT_FILE (use --force to regenerate)."
  if [[ ! -f "$HTML_FILE" ]]; then
    render_html "$OUTPUT_FILE" "$HTML_FILE" || true
  fi
  if [[ "$INTERACTIVE" == "true" ]]; then
    cat "$OUTPUT_FILE"
  fi
  exit 0
fi

INGREDIENTS=$(grep -v '^\s*#' "$INGREDIENTS_FILE" | grep -v '^\s*$' || true)

if [[ -z "$INGREDIENTS" ]]; then
  log "ingredients.txt is empty, skipping."
  exit 0
fi

PANTRY=""
if [[ -f "$PANTRY_FILE" ]]; then
  PANTRY=$(grep -v '^\s*#' "$PANTRY_FILE" | grep -v '^\s*$' || true)
fi

RECENT_RECIPES=""
setopt NULL_GLOB
RECIPE_FILES=("$RECIPES_DIR"/*.md(Nom))
unsetopt NULL_GLOB
if (( ${#RECIPE_FILES[@]} > 0 )); then
  for f in "${RECIPE_FILES[@]:0:7}"; do
    RECENT_RECIPES+=$'\n--- '"$(basename "$f" .md)"$' ---\n'
    RECENT_RECIPES+="$(cat "$f")"
    RECENT_RECIPES+=$'\n'
  done
fi

PROMPT="You are a home cook planning a meal for $TARGET_DATE. Produce a single markdown document with TWO parts:

PART A — Three 'cook-right-now' options:
Propose THREE distinct recipe options that use ONLY the 'Ingredients on hand' and 'Pantry staples' listed below. NO MISSING items. NO shopping trip. Every ingredient in these three recipes must come from one of the two lists. If you catch yourself wanting to add something not in either list, pick a different dish instead.

PART B — One 'recommended' recipe (stretch option):
After the three options, propose ONE additional recipe that the user should consider making if they're willing to buy 1–2 small items. Use everything on hand + pantry PLUS at most TWO additional ingredients. Each of those added ingredients MUST be clearly tagged '**(MISSING — need to buy)**'. Aim for something a bit more exciting or elevated than the three constrained options — the kind of dish worth a quick shop.

Every recipe (A and B) must satisfy:
1. SIMPLE: low cooking time (prefer <= 30 min active) and low effort (few steps, minimal equipment).
2. NUTRITIOUS & HEALTHY: balanced protein, veg, and whole ingredients. Avoid deep-frying and heavy processed ingredients.
3. DETAILED: give exact quantities (grams, tsp, tbsp, cups) and exact times/temperatures (e.g., 'sauté 3–4 min over medium heat', 'bake at 200°C for 12 min'). No vague 'some' or 'a bit'.
4. DIVERSE: the three 'cook-now' options should differ from each other in cuisine, main protein, or cooking method. The recommended recipe should also differ. AVOID repeating recipes from the recent history below — no same dish; try to vary cuisine/protein/method from the last few days.

Ingredients on hand:
$INGREDIENTS

Pantry staples (always available, do NOT tag as missing):
$PANTRY

Recent recipes (avoid repeating these):
$RECENT_RECIPES

Output format (a single markdown document):

# Recipes for $TARGET_DATE

## Option 1: <Dish Name>
One-line description.
**Prep time**: X min | **Cook time**: X min | **Serves**: X
**Ingredients**
- exact quantities (no MISSING tags — every item is on hand or pantry)
**Steps**
1. Numbered with exact times & temperatures.
**Why it's healthy**: one short line.

## Option 2: ...
## Option 3: ...

---

## Recommended: <Dish Name> (needs 1–2 extra items)
One-line description explaining why this is worth a small shop.
**Prep time** / **Cook time** / **Serves**
**Ingredients** — with exactly 1 or 2 items tagged '**(MISSING — need to buy)**'; all others from the two lists.
**Steps** — numbered with exact times & temps.
**Why it's healthy**: one short line.

Output only the markdown, no preamble."

log "Generating recipes for $TARGET_DATE..."

if claude -p "$PROMPT" > "$OUTPUT_FILE" 2>> "$LOG_FILE"; then
  log "Wrote $OUTPUT_FILE"
  if render_html "$OUTPUT_FILE" "$HTML_FILE"; then
    log "Rendered $HTML_FILE"
  fi
  if [[ "$INTERACTIVE" == "true" ]]; then
    cat "$OUTPUT_FILE"
  else
    open_path="$HTML_FILE"
    [[ -f "$HTML_FILE" ]] || open_path="$OUTPUT_FILE"
    notify_dialog "Recipes for $TARGET_DATE" "Three recipe options are ready. Open to pick one." "$open_path"
  fi
else
  log "claude CLI failed, see log above."
  rm -f "$OUTPUT_FILE"
  if [[ "$INTERACTIVE" == "true" ]]; then
    echo "Recipe generation failed. See $LOG_FILE." >&2
  else
    notify_dialog "Recipe generator error" "Generation failed. Check $LOG_FILE."
  fi
  exit 1
fi
