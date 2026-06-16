# Contributing to LumoraTV

Thanks for your interest!

## License of contributions

LumoraTV is licensed under **Apache-2.0**. Unless you state otherwise, any contribution you
intentionally submit for inclusion in the project is provided under the same Apache-2.0 terms,
with no additional conditions (inbound = outbound, per section 5 of the license). The Apache-2.0
patent grant applies to your contribution.

You don't need a CLA or DCO sign-off, but a `Signed-off-by` trailer (`git commit -s`) is welcome
if you want to make your authorship explicit.

## Technical ground rules

- No Xcode IDE artifacts: the project is defined in `project.yml` (XcodeGen). Never commit
  `LumoraTV.xcodeproj` changes — regenerate with `xcodegen generate`.
- Swift 6 strict concurrency must build clean.
- Keep the dependency on the **LGPL (non-GPL) variant of MPVKit** (do not switch to `MPVKit-GPL`).
- UI text goes through the `L10n` system (EN + ES), never hardcoded.
- Per-user data (watch state, lists, ratings) goes through the existing stores.
