#!/bin/zsh
set -uo pipefail

SCRIPT="${0:A:h}/../kitchen.sh"
FAILS=0

pass() { print -P "  %F{green}ok%f   $1"; }
fail() { print -P "  %F{red}FAIL%f $1"; FAILS=$((FAILS + 1)); }

assert_eq() {
  if [[ "$2" == "$3" ]]; then pass "$1"
  else fail "$1"; print "       expected: [$2]"; print "       actual:   [$3]"; fi
}
assert_contains() {
  if [[ "$2" == *"$3"* ]]; then pass "$1"
  else fail "$1 (missing: $3)"; fi
}
assert_not_contains() {
  if [[ "$2" != *"$3"* ]]; then pass "$1"
  else fail "$1 (unexpected: $3)"; fi
}

new_data_dir() { export KITCHEN_DATA_DIR="$(mktemp -d)"; }
k() { REPLY_OUT="$("$SCRIPT" "$@" 2>&1)"; REPLY_RC=$?; }

echo "== dispatch & usage =="
new_data_dir
k --help
assert_eq "help exits 0" 0 "$REPLY_RC"
assert_contains "help shows usage" "$REPLY_OUT" "Usage: kitchen"

k
assert_eq "no args exits 2" 2 "$REPLY_RC"

k bogus
assert_eq "unknown command exits 2" 2 "$REPLY_RC"
assert_contains "unknown command message" "$REPLY_OUT" "unknown command"

echo "== list =="
new_data_dir
k list ingredients
assert_contains "empty list shows header" "$REPLY_OUT" "== ingredients =="
assert_contains "empty list shows (none)" "$REPLY_OUT" "(none)"

new_data_dir
printf '# comment\n\nspinach !urgent\neggs\n' > "$KITCHEN_DATA_DIR/ingredients.txt"
printf 'salt\nrice\n' > "$KITCHEN_DATA_DIR/pantry.txt"
k list ingredients
assert_contains "list shows plain item" "$REPLY_OUT" "eggs"
assert_contains "list flags urgent item" "$REPLY_OUT" "spinach ⚠ urgent"
assert_not_contains "list omits comments" "$REPLY_OUT" "# comment"

k list
assert_contains "list both shows ingredients header" "$REPLY_OUT" "== ingredients =="
assert_contains "list both shows pantry header" "$REPLY_OUT" "== pantry =="
assert_contains "list both shows pantry item" "$REPLY_OUT" "rice"

k list bogus
assert_eq "list bad target exits 2" 2 "$REPLY_RC"

echo "== add =="
new_data_dir
printf '# my stuff\neggs\n' > "$KITCHEN_DATA_DIR/ingredients.txt"
k add ingredients "chicken thighs"
assert_eq "add exits 0" 0 "$REPLY_RC"
assert_contains "add reports added" "$REPLY_OUT" "Added to ingredients: chicken thighs"
k list ingredients
assert_contains "added item present" "$REPLY_OUT" "chicken thighs"
assert_contains "add preserves existing item" "$REPLY_OUT" "eggs"
assert_not_contains "add preserves comment (not listed)" "$REPLY_OUT" "my stuff"
assert_contains "comment still in file" "$(cat "$KITCHEN_DATA_DIR/ingredients.txt")" "# my stuff"

k add ingredients "EGGS"
assert_contains "duplicate is skipped (case-insensitive)" "$REPLY_OUT" "Already in ingredients: EGGS"

k add ingredients "kale" --urgent
assert_contains "urgent add reported" "$REPLY_OUT" "Added to ingredients: kale"
k list ingredients
assert_contains "urgent flag applied" "$REPLY_OUT" "kale ⚠ urgent"

new_data_dir
k add pantry "fish sauce"
assert_contains "add to pantry, file created" "$REPLY_OUT" "Added to pantry: fish sauce"
assert_eq "pantry file now exists" "fish sauce" "$(cat "$KITCHEN_DATA_DIR/pantry.txt")"

k add pantry "miso" --urgent
assert_eq "--urgent with pantry exits 2" 2 "$REPLY_RC"
k add bogus "x"
assert_eq "add bad list exits 2" 2 "$REPLY_RC"
k add ingredients
assert_eq "add with no items exits 2" 2 "$REPLY_RC"

echo "== remove =="
new_data_dir
printf '# header\ncherry tomatoes\nspinach !urgent\neggs\n' > "$KITCHEN_DATA_DIR/ingredients.txt"

k remove ingredients "Spinach"
assert_contains "remove reports removed (case-insensitive, urgent line)" "$REPLY_OUT" "Removed from ingredients: Spinach"
k list ingredients
assert_not_contains "removed item gone" "$REPLY_OUT" "spinach"
assert_contains "other items remain" "$REPLY_OUT" "eggs"
assert_contains "comment preserved after remove" "$(cat "$KITCHEN_DATA_DIR/ingredients.txt")" "# header"

k remove ingredients "tom"
assert_eq "remove missing exits 0" 0 "$REPLY_RC"
assert_contains "exact match: substring not removed" "$REPLY_OUT" "Not found in ingredients: tom"
k list ingredients
assert_contains "substring target untouched" "$REPLY_OUT" "cherry tomatoes"

k remove bogus "x"
assert_eq "remove bad list exits 2" 2 "$REPLY_RC"
k remove ingredients
assert_eq "remove with no items exits 2" 2 "$REPLY_RC"

echo "== urgent / unurgent =="
new_data_dir
printf '# h\nspinach\neggs\n' > "$KITCHEN_DATA_DIR/ingredients.txt"

k urgent "spinach"
assert_contains "urgent marks item" "$REPLY_OUT" "Marked urgent: spinach"
k list ingredients
assert_contains "urgent flag shown" "$REPLY_OUT" "spinach ⚠ urgent"

k urgent "spinach"
assert_contains "urgent is idempotent" "$REPLY_OUT" "Marked urgent: spinach"
assert_eq "no double suffix" "spinach !urgent" "$(grep -i spinach "$KITCHEN_DATA_DIR/ingredients.txt")"

k unurgent "SPINACH"
assert_contains "unurgent clears (case-insensitive)" "$REPLY_OUT" "Cleared urgent: SPINACH"
k list ingredients
assert_not_contains "urgent flag gone" "$REPLY_OUT" "⚠ urgent"

k urgent "kale"
assert_contains "urgent missing item reported" "$REPLY_OUT" "Not found in ingredients: kale"
assert_eq "urgent missing exits 0" 0 "$REPLY_RC"
assert_contains "comment preserved after urgent ops" "$(cat "$KITCHEN_DATA_DIR/ingredients.txt")" "# h"

k urgent
assert_eq "urgent with no items exits 2" 2 "$REPLY_RC"

echo
if (( FAILS > 0 )); then print -P "%F{red}$FAILS failure(s)%f"; exit 1
else print -P "%F{green}all tests passed%f"; fi
