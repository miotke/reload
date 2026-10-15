import Foundation

/// Required add-ons: which are missing, what could provide them, and who needs whom
/// (docs/features/dependencies.md). Local only: the TOCs on disk and the metadata database.
extension AddonManager {
    public func missingDependencies(in installation: Installation) async -> [MissingDependency] {
        guard let managed = try? await store.addons(in: installation) else { return [] }
        return await missingDependencies(for: managed, managed: managed, in: installation)
    }

    public func missingDependencies(of ref: AddonRef, in installation: Installation) async -> [MissingDependency] {
        guard let managed = try? await store.addons(in: installation),
              let addon = managed.first(where: { $0.id == ref }) else { return [] }
        return await missingDependencies(for: [addon], managed: managed, in: installation)
    }

    /// Managed add-ons other than `ref` whose loaded TOC requires a folder `ref` owns that no
    /// other folder in `AddOns/` provides.
    public func dependents(of ref: AddonRef, in installation: Installation) async -> [InstalledAddon] {
        guard let managed = try? await store.addons(in: installation),
              let target = managed.first(where: { $0.id == ref }) else { return [] }
        let others = managed.filter { $0.id != ref }
        let scan = await Self.scanDependencies(others, in: installation)
        let owned = Set(target.folders.map { $0.lowercased() })
        let elsewhere = scan.present.subtracting(owned)
        return others
            .filter { addon in
                (scan.required[addon.id] ?? []).contains { owned.contains($0.lowercased()) && !elsewhere.contains($0.lowercased()) }
            }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    /// Missing folders `addons` require, grouped by folder in name order, with candidates.
    /// `managed` is every managed add-on, for naming candidates that are installed.
    func missingDependencies(for addons: [InstalledAddon], managed: [InstalledAddon], in installation: Installation) async -> [MissingDependency] {
        let scan = await Self.scanDependencies(addons, in: installation)
        var missing: [MissingDependency] = []
        var byFolder: [String: Int] = [:]
        for addon in addons.sorted(by: { $0.name.localizedStandardCompare($1.name) == .orderedAscending }) {
            for folder in scan.required[addon.id] ?? [] where !scan.present.contains(folder.lowercased()) {
                if let index = byFolder[folder.lowercased()] {
                    missing[index].requiredBy.append(addon.id)
                } else {
                    byFolder[folder.lowercased()] = missing.count
                    missing.append(MissingDependency(folder: folder, requiredBy: [addon.id]))
                }
            }
        }
        guard !missing.isEmpty else { return [] }
        missing.sort { $0.folder.localizedStandardCompare($1.folder) == .orderedAscending }
        return await withCandidates(missing, managed: managed)
    }

    /// Fills each dependency's candidates from sources that are on: downloaded releases'
    /// folders, hosted listings' folders, then catalogue names.
    private func withCandidates(_ missing: [MissingDependency], managed: [InstalledAddon]) async -> [MissingDependency] {
        let enabled = await database.enabledSources()
        let folders = missing.map(\.folder)
        let shipped = await database.releasesShipping(folders).filter { enabled.contains($0.ref.source) }
        let listed = await database.hostedEntries(shipping: folders, sources: enabled.subtracting([.github]))
        let index = enabled.contains(.github) ? await catalogue.adoptionIndex() : nil

        var names: [String: String] = [:]
        for addon in managed { names[addon.id.key.lowercased()] = addon.name }
        for ref in Set(shipped.map(\.ref)) where names[ref.key.lowercased()] == nil {
            names[ref.key.lowercased()] = await catalogue.entry(for: ref)?.name ?? ref.repoName
        }

        return missing.map { dependency in
            let folder = dependency.folder.lowercased()
            let downloaded = shipped.filter { $0.folder.lowercased() == folder }
                .map { DependencyMatcher.Downloaded(ref: $0.ref, name: names[$0.ref.key.lowercased()] ?? $0.ref.repoName) }
            let hosted = listed.filter { $0.folder.lowercased() == folder }.map(\.entry)
            let named = index?.candidates(folder: dependency.folder, hints: TocHints()) ?? []
            let ranked = DependencyMatcher.rank(folder: dependency.folder, downloaded: downloaded, listed: hosted, named: named)
            var dependency = dependency
            dependency.candidates = ranked.candidates
            dependency.suggested = ranked.suggested
            return dependency
        }
    }

    /// What every folder in `AddOns/` is, and the folders each add-on's loaded TOCs require.
    struct DependencyScan: Sendable {
        /// Lower-cased names of every folder in `AddOns/`, managed or not.
        var present: Set<String> = []
        /// Required folders as the TOCs spell them, without `Blizzard_*` ones and the add-on's
        /// own folders (a missing own folder is a missing folder, not a dependency).
        var required: [AddonRef: [String]] = [:]
    }

    /// Reads the TOC the game loads for the installation's flavor in each of the add-ons'
    /// folders (the `ZipInspector` rule). Off the actor: it reads one directory and a few
    /// small files per add-on.
    @concurrent
    static func scanDependencies(_ addons: [InstalledAddon], in installation: Installation) async -> DependencyScan {
        let directory = installation.addonsDirectory
        var scan = DependencyScan()
        let entries = (try? FileManager.default.contentsOfDirectory(atPath: directory.path(percentEncoded: false))) ?? []
        for entry in entries where !entry.hasPrefix(".") && InstallStore.isDirectory(directory.appending(path: entry, directoryHint: .isDirectory)) {
            scan.present.insert(entry.lowercased())
        }
        for addon in addons {
            let own = Set(addon.folders.map { $0.lowercased() })
            var required: [String] = []
            var seen = Set<String>()
            for folder in addon.folders where scan.present.contains(folder.lowercased()) {
                let tocs = ZipInspector.readTocs(addonFolder: directory.appending(path: folder, directoryHint: .isDirectory), flavor: installation.flavor)
                guard tocs.isLoaded, let loaded = tocs.loaded else { continue }
                for dependency in loaded.toc.requiredDependencies {
                    let key = dependency.lowercased()
                    guard !Installer.isProtected(dependency), !own.contains(key), seen.insert(key).inserted else { continue }
                    required.append(dependency)
                }
            }
            if !required.isEmpty { scan.required[addon.id] = required }
        }
        return scan
    }
}

// MARK: - Database access

extension MetadataDatabase {
    /// Releases whose last download shipped one of `folders` (any case), keyed as stored.
    func releasesShipping(_ folders: [String]) -> [(ref: AddonRef, folder: String)] {
        guard !folders.isEmpty else { return [] }
        let marks = Array(repeating: "?", count: folders.count).joined(separator: ", ")
        let rows = (try? query("""
            SELECT r.full_name, f.value FROM release_folders r, json_each(r.folders_json) f
            WHERE lower(f.value) IN (\(marks))
            """, folders.map { $0.lowercased() })) ?? []
        return rows.compactMap { row in
            guard let key = row.string(0), let folder = row.string(1) else { return nil }
            return (AddonRef(key: key), folder)
        }
    }

    /// Hosted catalogue rows from `sources` whose listing names one of `folders` (any case).
    func hostedEntries(shipping folders: [String], sources: Set<SourceID>) -> [(folder: String, entry: CatalogueEntry)] {
        guard !folders.isEmpty, !sources.isEmpty else { return [] }
        let columns = Self.catalogueReadColumns.split(separator: ",")
            .map { "c." + $0.trimmingCharacters(in: .whitespacesAndNewlines) }.joined(separator: ", ")
        let sourceMarks = Array(repeating: "?", count: sources.count).joined(separator: ", ")
        let folderMarks = Array(repeating: "?", count: folders.count).joined(separator: ", ")
        let arguments: [any SQLBindable] = sources.map(\.rawValue).sorted() + folders.map { $0.lowercased() }
        let rows = (try? query("""
            SELECT f.value, \(columns) FROM catalogue c, json_each(c.folders_json) f
            WHERE c.folders_json IS NOT NULL AND c.source IN (\(sourceMarks)) AND lower(f.value) IN (\(folderMarks))
            """, arguments)) ?? []
        return rows.compactMap { row in
            guard let folder = row.string(0), let entry = Self.entry(SQLRow(values: Array(row.values.dropFirst()))) else { return nil }
            return (folder, entry)
        }
    }
}
