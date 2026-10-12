# CLI config

The `addonctl config` keys and where they're stored, the `addons.json` export format, and the CLI's current limits.

Commands: [commands.md](commands.md). Where files live: [data-storage.md](../architecture/data-storage.md).

## Config keys

| Key | Stored in | Notes |
|---|---|---|
| `github-token` | Keychain (service `com.andrewmiotke.ForeverAddons`, account `github-token`) | Shared with the app's Settings |
| `default-channel` | `<Application Support>/config.json` | `stable` or `prerelease` |
| `default-install` | `<Application Support>/config.json` | Validated against known installations; a path is added first |

### `github-token`

- `set` reads stdin (no echo on a terminal) and **refuses a value on the command line**, so the token doesn't end up in shell history.
- `get` prints it masked (`ghp_…abcd`) with its source.
- `ADDONS_GITHUB_TOKEN` and `GITHUB_TOKEN` win over the Keychain ([output.md](output.md#environment)).
- A token raises the API limit from 60 to 5,000 calls an hour ([github-endpoints.md](../network/github-endpoints.md#quota)).

```sh
addonctl config set github-token < token.txt
addonctl config get github-token
addonctl config unset github-token
```

## `addons.json`

Written by `export`, read by `import`. Use it to share a setup or move to another Mac.

```json
{
  "schemaVersion": 1,
  "exportedAt": "2026-10-11T23:49:53Z",
  "addons": [
    { "ref": "github:BigWigsMods/BigWigs", "name": "BigWigs", "channel": "stable", "pinned": true, "version": "v426.4" }
  ]
}
```

| Field | Notes |
|---|---|
| `ref` | `github:owner/repo` form |
| `name` | For display |
| `channel` | `stable` or `prerelease` |
| `pinned` | Restored on import |
| `version` | Written only for pinned add-ons |

`import` installs every entry not already installed. For installed ones it only syncs channel and pin.

## Limits

- `install --version <tag>` only succeeds when `<tag>` is the release the selector picks today (then it installs and pins it). AddonKit can't install an older tag yet. `import` warns and installs the current release (still pinned) in that case.
- `search` shows stored verdicts only. Add-ons that were never opened, installed or refreshed show `? unknown` until the next refresh ([refresh.md](../features/refresh.md)).
- Only GitHub is a source today. The `github:` prefix leaves room for others ([decision 0002](../decisions/0002-github-releases-no-keyed-apis.md)).
