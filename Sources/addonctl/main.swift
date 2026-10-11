import AddonKit
import ArgumentParser

@main
struct AddonCtl: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "addonctl",
        abstract: "Manage World of Warcraft Forever add-ons.",
        subcommands: []
    )
}
