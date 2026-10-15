# Contributing

## Development

Use Linux, Elixir 1.19+, and OTP 28+. Run:

```sh
mix deps.get
mix ci
mix docs --warnings-as-errors
mix hex.build
```

`mix ci` checks compilation, formatting, tests, Credo, Dialyzer, duplication, and
architecture rules. Tests do not start the default application or attach to a
workstation daemon. Keep new integration tests isolated, with temporary state and
sockets; do not change host networking.

To include real-daemon tests, set `TAILSCALED_TEST_BINARY` to an absolute path.
`TAILSCALE_TEST_NETWORK=1` additionally enables tests that contact Tailscale's
control plane. These tests do not establish enrolled-tailnet or hardware support.

Include regression tests for behavior changes. Describe user-visible changes in
`CHANGELOG.md` under `Unreleased`, including migration steps for breaking changes.
Do not use commit logs, test counts, or internal refactors as release notes.

When reporting problems, include library/daemon versions and the platform.
Never post auth keys, identity files, enrollment URLs, or unredacted daemon logs.

## Release checklist

Publication is manual. Building the package or pushing a commit does not publish it.

1. Choose the version, update `mix.exs`, and move `Unreleased` entries into a
   `## X.Y.Z - YYYY-MM-DD` section. Keep an empty `Unreleased` section above it.
2. Update the README's installation instructions when the first Hex version is ready.
3. Run the checks above, including isolated real-daemon tests. Inspect the package
   contents: include source and documentation, never downloaded binaries or state.
4. Test the built package in a fresh consumer project without starting its application.
5. Commit the reviewed release changes and publish the Hex package and HexDocs.
6. Push the matching `vX.Y.Z` tag and create the GitHub Release. Its title must be
   exactly the tag; its body must be exactly the matching changelog section body,
   excluding the version heading. Use a notes file, not generated release notes.
7. Verify the registry version, HexDocs, remote tag, and GitHub Release contents.

Before 1.0, breaking API changes belong in a new minor version; document them
explicitly rather than treating every 0.x change as implicitly compatible.
