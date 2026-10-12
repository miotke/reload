# Errors

The `AddonError` cases the core throws, what users see for each, and how the CLI maps them to exit codes.

Code: `Sources/AddonKit/Model/AddonError.swift`. CLI mapping: `Sources/addonctl/Errors.swift`.

Everything in AddonKit throws `AddonError`. Each case has a user-facing `errorDescription`, which the app shows inline on the row and in the inspector, and the CLI prints as `error: <message>`.

## AddonError

| Case | Message (shortened) | Raised by | CLI exit code |
|---|---|---|---|
| `invalidReference(String)` | Not a valid add-on reference | `GitHubSource` ref handling, `import` | 2 |
| `notFound(AddonRef)` | … was not found | GitHub 404 on the release list | 1 |
| `noCompatibleRelease(AddonRef, Flavor)` | … has no *<flavor>* build yet (e.g. Forever) | [release selection](../features/release-selection.md) | 1 |
| `rateLimited(resetAt:)` | GitHub rate limit reached. Try again … | 403/429 with no quota left, `retry-after`, or a secondary rate limit | 4 |
| `http(status:url:)` | HTTP *n* from *host* | any other non-2xx (GitHub, catalogue) | 1 |
| `invalidArchive(String)` | Invalid add-on archive | `ZipExtractor` | 1 |
| `unsafeArchivePath(String)` | Archive contains an unsafe path | `ZipExtractor` (zip-slip) | 1 |
| `folderConflict(folder:owner:)` | … is already installed by … | `Installer` ownership check | 5 |
| `unmanagedFolderExists(String)` | … already exists and isn't managed. Overwrite it? | `Installer`; retry with `force` | 5 |
| `notInstalled(AddonRef)` | … isn't installed | update, uninstall, rollback, pin, channel | 1 |
| `noRollbackAvailable(AddonRef)` | No previous version … is cached | `rollback` | 1 |
| `installationNotFound(String)` | Installation … not found | `InstallationLocator.installation(at:)` | 1 |
| `cannotRemove(folder:reason:)` | Can't move … to the Trash: it … | `removeUnmanaged` (Blizzard, managed, outside `AddOns/`, missing); nothing is moved | 1 |

The installing rules behind the archive and folder errors are in [installing.md](../features/installing.md).

## How front ends use them

- **App:** errors show as a red icon on the affected row with the message in its tooltip and in the inspector. `unmanagedFolderExists` turns into an **Overwrite** confirmation. One failed add-on never stops **Update All**.
- **CLI:** see [cli/output.md](../cli/output.md#exit-codes). The CLI adds its own `CLIError` cases for usage problems (ambiguous refs or installations, missing confirmation, partial failure).
- **`update` streams** report failures as `OperationEvent.failed(ref, message)`, a string, so the CLI recognises rate limiting there from the message text.

## Rate limits are not failures to retry

`rateLimited` means stop calling GitHub until `resetAt`. Callers must not retry in a loop. The rules are in [network/overview.md](../network/overview.md).

## Adding a case

- Give it a user-facing `errorDescription` that says what to do next where possible.
- Map it in `ExitStatus.code(for:)` and the JSON error codes in `Sources/addonctl/Errors.swift`.
