# Dependencies

Add-ons that need other add-ons: how Reload finds missing ones, offers to install them, and warns before removing one that others need.

Code: `Sources/AddonKit/Model/Dependencies.swift` (contract). Being built for 0.1.6.

## The contract

- `AddonManaging.missingDependencies(in:)` and `missingDependencies(of:in:)`: folders a managed add-on's loaded TOC requires that aren't in `AddOns/`, with candidates to install. Local only.
- `AddonManaging.dependents(of:in:)`: managed add-ons that would stop loading without a given add-on.
- `DependencyPolicy`: what a front end does after an install leaves dependencies missing (ask, install, warn).
