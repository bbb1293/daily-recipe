# Project instructions

## Release workflow

After introducing a new feature, ask whether to:

1. Create a commit.
2. Push to `origin`.
3. Add an appropriate annotated semver tag (e.g. `v0.5.0`) and push it.

The project uses `vMAJOR.MINOR.PATCH` annotated tags with subject lines shaped like `vX.Y.Z — <short description>`. Run `git tag -l --format='%(refname:short) %(subject)' --sort=-creatordate | head` to see recent examples before picking the next version.
