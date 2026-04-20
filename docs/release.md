# Release Process

PowerGrid uses `master` as the trunk and tagged release branch.

## Branch Model

- land feature and fix commits on `master`
- tag releases from `master`
- avoid a parallel long-lived `dev` branch unless it materially changes day-to-day work

## Patch Release Checklist

1. Finalize the release candidate on `master`.
2. Verify from repo root:

   ```bash
   make verify
   ```

3. Build an unsigned app locally if you need a release sanity check:

   ```bash
   make build
   ```

4. If the release depends on new `powerkit-go` APIs:
   - release and tag `powerkit-go` first
   - update `go.mod` to the new tag
   - rerun verification in PowerGrid
5. Tag the release on `master`:

   ```bash
   git tag vX.Y.Z
   ```

6. Push `master` and the new tag.

## Versioning Notes

- use semver tags on `master`
- daemon and app compatibility is gated primarily by RPC protocol versioning
- build IDs are diagnostic and upgrade signals, not the primary compatibility contract

## CI Expectations

CI should validate `master` and pull requests targeting `master`. If the branch model changes, update CI and this document together.
