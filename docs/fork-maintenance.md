# Fork maintenance

`main` stays linear on top of `JCPetrelli/TabChroma`:

```bash
git fetch upstream
git rebase upstream/main
git push --force-with-lease origin main
```

For a new fork release:

1. Bump `VERSION` to `<upstream-version>-codex.<n>` and tag it with a leading `v`.
2. Push the tag to `origin`.
3. Update `Formula/tab-chroma.rb` to the tag URL, version, and archive SHA-256.
4. Push `main`, then verify with `brew update && brew upgrade tab-chroma`.

Do not move published tags. Create the next `-codex.<n>` tag instead.
