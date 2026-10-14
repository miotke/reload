import Foundation

/// The real `AddonManaging` implementation, shared by the app and `reload` (docs/architecture/core.md).
public actor AddonManager: AddonManaging {
    public nonisolated let directories: AppDirectories
    public nonisolated let store: InstallStore

    let http: any HTTPClient
    let locator: InstallationLocator
    let installer: Installer
    let downloader: Downloader
    let keychain: KeychainStore
    let environment: [String: String]
    /// Catalogue, support verdicts, details and refresh state (docs/architecture/core.md).
    public nonisolated let database: MetadataDatabase
    let catalogue: CatalogueSource
    /// WoWInterface and Tukui listings and latest files (docs/features/sources.md).
    let hosted: HostedCatalogue
    let supportCache: SupportCache
    let github: GitHub
    let githubSearch: GitHubSearchProvider
    let searchCoordinator: SearchCoordinator
    /// Automatic detection runs at most once per process; later scans are explicit.
    var didAutoDetect = false
    var now: @Sendable () -> Date = Date.init
    /// Lower-cased refs `checkVisible` is checking now, so a second call skips them.
    var visibleInFlight: Set<String> = []
    /// True on a constrained (Low Data Mode) network; `checkVisible` then does nothing.
    var networkIsConstrained: @Sendable () -> Bool = { NetworkPathMonitor.shared.isConstrained }

    /// Add-ons checked or updated at once.
    static let maxConcurrentOperations = 4

    public init(
        directories: AppDirectories = .standard(),
        http: any HTTPClient = URLSessionHTTPClient(),
        downloadTransport: any DownloadTransport = URLSessionDownloadTransport(),
        locator: InstallationLocator = InstallationLocator(),
        installer: Installer = Installer(),
        keychain: KeychainStore = KeychainStore(),
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) {
        self.directories = directories
        self.http = http
        self.locator = locator
        self.installer = installer
        self.keychain = keychain
        self.environment = environment
        self.store = InstallStore(directories: directories)
        let downloader = Downloader(cachesDirectory: directories.caches, transport: downloadTransport)
        self.downloader = downloader
        // If the file can't be opened (disk full, permissions), work from memory this session.
        let database = (try? MetadataDatabase(directories: directories)) ?? (try! MetadataDatabase.inMemory())
        self.database = database
        let catalogue = CatalogueSource(http: http, database: database)
        self.catalogue = catalogue
        self.hosted = HostedCatalogue(http: http, database: database, catalogue: catalogue)
        let supportCache = SupportCache(database: database)
        self.supportCache = supportCache

        // The Keychain is read on first GitHub use, not here: init runs on the main thread at
        // launch and a Keychain prompt would block it.
        let tokenProvider: @Sendable () -> String? = { Self.token(environment: environment, keychain: keychain) }
        self.github = GitHub(
            http: http, cacheDirectory: directories.caches, database: database, store: supportCache, tokenProvider: tokenProvider,
            archiveURL: { downloader.archiveURL(for: $0) }
        )
        self.githubSearch = GitHubSearchProvider(http: http, database: database, tokenProvider: tokenProvider)
        self.searchCoordinator = SearchCoordinator(catalogue: catalogue, github: githubSearch, supportCache: supportCache, hosted: hosted)
    }

    /// `RELOAD_GITHUB_TOKEN`, then `GITHUB_TOKEN`, then the Keychain (docs/architecture/core.md).
    static func token(environment: [String: String], keychain: KeychainStore) -> String? {
        for key in ["RELOAD_GITHUB_TOKEN", "GITHUB_TOKEN"] {
            if let value = environment[key]?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty {
                return value
            }
        }
        return keychain.get()
    }

    /// Picks up a new token, keeping ETags, cached release.json files and rate-limit state.
    public func tokenDidChange() async {
        let token = Self.token(environment: environment, keychain: keychain)
        await github.api.setToken(token)
        await githubSearch.setToken(token)
    }

    /// Tests skip the backoff sleeps between github.com retries.
    func setRetryDelay(_ delay: @escaping @Sendable (Int, TimeInterval?) -> Duration) async {
        await github.web.setRetryDelay(delay)
    }

    func setClock(_ clock: @escaping @Sendable () -> Date) async {
        now = clock
        await github.setClock(clock)
        await hosted.setClock(clock)
    }
}
