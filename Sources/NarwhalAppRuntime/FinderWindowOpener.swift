import AppKit

enum FinderWindowOpenError: Error, CustomStringConvertible {
    case fileViewerRejected(path: String)

    var description: String {
        switch self {
        case .fileViewerRejected(let path):
            return "Finder file viewer rejected path \(path)"
        }
    }
}

enum FinderWindowOpener {
    @MainActor
    static func openHomeWindow() throws {
        let homePath = FileManager.default.homeDirectoryForCurrentUser.path
        guard NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: homePath) else {
            throw FinderWindowOpenError.fileViewerRejected(path: homePath)
        }
    }
}
