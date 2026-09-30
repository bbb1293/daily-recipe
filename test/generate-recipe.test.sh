#!/bin/zsh
set -euo pipefail

# Exercise the real script in a disposable project, without model calls,
# notifications, or changes to personal ingredients and recipe history.
PROJECT_DIR="${0:A:h:h}"
TEST_DIR=$(mktemp -d)
trap 'rm -rf -- "$TEST_DIR"' EXIT
mkdir -p "$TEST_DIR/project/recipes" "$TEST_DIR/bin" "$TEST_DIR/tmp"
cp "$PROJECT_DIR/generate-recipe.sh" "$PROJECT_DIR/recipe.css" "$TEST_DIR/project/"
printf 'spinach !urgent\neggs\n' > "$TEST_DIR/project/ingredients.txt"
printf 'rice\nsalt\n' > "$TEST_DIR/project/pantry.txt"
printf '# Earlier dish\nDo not repeat this dish.\n' > "$TEST_DIR/project/recipes/2026-01-01.md"

export PATH="$TEST_DIR/bin:$PATH"
export TMPDIR="$TEST_DIR/tmp/"
export TEST_CALLS="$TEST_DIR/calls" TEST_ARGS="$TEST_DIR/args" TEST_PROMPT="$TEST_DIR/prompt"
export TEST_MODE=success
unset RECIPE_PROVIDER RECIPE_MODEL RECIPE_LANGUAGE

cat > "$TEST_DIR/bin/model-mock" <<'MOCK'
#!/bin/zsh
set -euo pipefail
provider="${0:t}"
print -r -- "$provider" >> "$TEST_CALLS"
printf '<%s>\n' "$@" > "$TEST_ARGS"
cat > "$TEST_PROMPT"
output_file=""
while (( $# > 0 )); do
  if [[ "$1" == "--output-last-message" ]]; then
    output_file="$2"
    shift 2
  else
    shift
  fi
done
print -u2 'mock progress on stderr'
recipe=$'# Test recipe\n\n## Spinach rice\nMock recipe body.'
[[ "$TEST_MODE" == empty ]] && recipe=$' \n\t'
if [[ "$provider" == codex ]]; then
  print 'mock progress on stdout (must not be served as a recipe)'
  [[ -n "$output_file" ]] || exit 9
  if [[ "$TEST_MODE" != missing ]]; then
    print -r -- "$recipe" > "$output_file"
  fi
else
  print -r -- "$recipe"
fi
[[ "$TEST_MODE" != fail ]] || exit 7
MOCK
cp "$TEST_DIR/bin/model-mock" "$TEST_DIR/bin/claude"
cp "$TEST_DIR/bin/model-mock" "$TEST_DIR/bin/codex"
# Rendering is optional and out of scope for these model integration tests.
printf '#!/bin/sh\nexit 1\n' > "$TEST_DIR/bin/pandoc"
chmod +x "$TEST_DIR/bin/claude" "$TEST_DIR/bin/codex" "$TEST_DIR/bin/pandoc"

SCRIPT="$TEST_DIR/project/generate-recipe.sh"
OUT="$TEST_DIR/stdout"
ERR="$TEST_DIR/stderr"
FAILS=0
CHECKS=0
RC=0
run_recipe() {
  RC=0
  zsh "$SCRIPT" "$@" > "$OUT" 2> "$ERR" || RC=$?
}
check() {
  local label="$1"
  shift
  CHECKS=$((CHECKS + 1))
  if "$@"; then print "ok: $label"
  else print "FAIL: $label"; FAILS=$((FAILS + 1)); fi
}

run_recipe --use eggs
check 'Codex is the default' grep -qx codex "$TEST_CALLS"
check 'default Codex generation succeeds' test "$RC" -eq 0
check 'default output is recipe markdown' grep -qx '# Test recipe' "$OUT"
check 'default output omits progress' test "$(grep -c progress "$OUT" || true)" -eq 0

: > "$TEST_CALLS"
run_recipe --provider claude --use eggs
check 'Claude can be selected explicitly' grep -qx claude "$TEST_CALLS"
check 'Claude succeeds' test "$RC" -eq 0
check 'Claude receives print mode and disabled tools' grep -qx '<-p>' "$TEST_ARGS"
check 'Claude receives the original prompt' grep -q 'Named ingredients' "$TEST_PROMPT"
check 'ad-hoc output is recipe markdown' grep -qx '# Test recipe' "$OUT"
check 'ad-hoc output omits progress' test "$(grep -c progress "$OUT" || true)" -eq 0

cat > "$TEST_DIR/project/config.sh" <<'CONFIG'
RECIPE_PROVIDER="codex"
RECIPE_MODEL="configured-model"
RECIPE_LANGUAGE="Korean"
CONFIG
: > "$TEST_CALLS"
run_recipe --use eggs --use spinach
check 'config selects Codex' grep -qx codex "$TEST_CALLS"
check 'Codex succeeds' test "$RC" -eq 0
check 'configured model is passed as an argument' grep -qx '<configured-model>' "$TEST_ARGS"
check 'Codex uses a read-only sandbox' grep -qx '<read-only>' "$TEST_ARGS"
check 'Codex skips coding config' grep -qx '<--ignore-user-config>' "$TEST_ARGS"
check 'all named ingredients reach the prompt' grep -q 'eggs, spinach' "$TEST_PROMPT"
check 'urgent items reach the prompt' grep -q 'URGENT' "$TEST_PROMPT"
check 'pantry reaches the prompt' grep -qx salt "$TEST_PROMPT"
check 'history reaches the prompt' grep -q 'Do not repeat this dish' "$TEST_PROMPT"
check 'language reaches the prompt' grep -q 'Write the entire output in Korean' "$TEST_PROMPT"
check 'only the final Codex response is returned' test "$(cat "$OUT")" = $'# Test recipe\n\n## Spinach rice\nMock recipe body.'

: > "$TEST_CALLS"
printf '\nRECIPE_PROVIDER="claude"\n' >> "$TEST_DIR/project/config.sh"
run_recipe --use eggs
check 'config can change the default to Claude' grep -qx claude "$TEST_CALLS"
: > "$TEST_CALLS"
run_recipe --provider codex --model 'override model' --use eggs
check 'CLI provider overrides config' grep -qx codex "$TEST_CALLS"
check 'CLI model overrides config as a single argument' grep -qx '<override model>' "$TEST_ARGS"

for provider in claude codex; do
  : > "$TEST_CALLS"
  run_recipe --provider "$provider" --date 2026-02-01 --force --print
  check "$provider daily generation succeeds" test "$RC" -eq 0
  check "$provider daily output is cached correctly" cmp -s "$OUT" "$TEST_DIR/project/recipes/2026-02-01.md"
  check "$provider daily prompt has both parts" grep -q 'PART B' "$TEST_PROMPT"
  : > "$TEST_CALLS"
  run_recipe --provider "$provider" --date 2026-02-01 --print
  check "$provider cache works without a model call" test ! -s "$TEST_CALLS"

  printf '# Original saved recipe\n' > "$TEST_DIR/project/recipes/2026-02-01.md"
  export TEST_MODE=fail
  run_recipe --provider "$provider" --use eggs
  check "$provider failure exits nonzero" test "$RC" -eq 1
  check "$provider failure emits no partial recipe" test ! -s "$OUT"
  run_recipe --provider "$provider" --date 2026-02-01 --force --print
  check "$provider failed regeneration preserves the cached recipe" grep -qx '# Original saved recipe' "$TEST_DIR/project/recipes/2026-02-01.md"
  run_recipe --provider "$provider" --date 2026-02-02 --print
  check "$provider failure creates no cache entry" test ! -e "$TEST_DIR/project/recipes/2026-02-02.md"

  export TEST_MODE=empty
  run_recipe --provider "$provider" --date 2026-02-02 --print
  check "$provider empty response fails" test "$RC" -eq 1
  check "$provider empty response is not cached" test ! -e "$TEST_DIR/project/recipes/2026-02-02.md"
  export TEST_MODE=success
done

export TEST_MODE=missing
run_recipe --provider codex --use eggs
check 'Codex missing final-response file fails' test "$RC" -eq 1
check 'Codex progress is not a fallback for missing output' test ! -s "$OUT"
export TEST_MODE=success

: > "$TEST_CALLS"
run_recipe --provider invalid --use eggs
check 'unknown provider is rejected' test "$RC" -eq 2
check 'invalid provider does not invoke a model' test ! -s "$TEST_CALLS"
run_recipe --provider
check 'missing provider value is rejected' test "$RC" -eq 2
run_recipe --model --use eggs
check 'missing model value is rejected' test "$RC" -eq 2
run_recipe --help
check 'help documents Codex' grep -q -- '--provider claude|codex' "$OUT"
check 'temporary model workspaces are cleaned up' test "$(ls -A "$TEST_DIR/tmp")" = ''

print "$CHECKS checks; $FAILS failures"
(( FAILS == 0 ))
