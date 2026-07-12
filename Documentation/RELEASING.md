# Releasing

1. Update `CHANGELOG.md` and public documentation.
2. Run the full validation matrix from `CONTRIBUTING.md`.
3. Run API compatibility analysis against the previous release tag.
4. Run `./Scripts/check-secrets.sh` and confirm GitHub secret scanning finds no
   credentials.
5. Merge through a reviewed pull request with green required checks.
6. Create an annotated three-component semantic version tag.
7. Push the tag and publish a GitHub release from it.
8. Verify a clean consumer resolves the remote tag and builds without sibling
   checkouts.

Never publish a tag that points at a commit different from the reviewed release
commit.
