# Project instructions

## Layout

Main logic lives in `generate-recipe.sh`. Data files are `ingredients.txt`, `pantry.txt`, and `recipes/`.

## Response style

Skip preamble and end-of-turn summaries. Answer directly.

## Feature suggestions

When the user proposes a feature, if you see a clearly better alternative (simpler, more reliable, or better fits the codebase), say so before implementing. Don't bikeshed minor stylistic choices — only speak up when the alternative is meaningfully better.

## Release workflow

After introducing a new feature, ask whether to:

1. Create a commit.
2. Push to `origin`.
3. Add an appropriate annotated semver tag (e.g. `v0.5.0`) and push it.

The project uses `vMAJOR.MINOR.PATCH` annotated tags with subject lines shaped like `vX.Y.Z — <short description>`. Run `git tag -l --format='%(refname:short) %(subject)' --sort=-creatordate | head` to see recent examples before picking the next version.
