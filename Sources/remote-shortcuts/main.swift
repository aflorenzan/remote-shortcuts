import Foundation
import RemoteShortcutsCore

// Thin shim: everything lives in RemoteShortcutsCore so it can be unit-tested.
exit(CLI.main(arguments: Array(CommandLine.arguments.dropFirst())))
