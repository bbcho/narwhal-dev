import Foundation

func readPrivateArtifact<Failure: Error>(
    at url: URL,
    maximumSize: Int,
    fileTooLarge: (Int, Int) -> Failure
) throws -> Data {
    let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
    if let byteCount = attributes[.size] as? NSNumber,
       byteCount.intValue > maximumSize {
        throw fileTooLarge(byteCount.intValue, maximumSize)
    }
    return try Data(contentsOf: url)
}

func writePrivateArtifact(_ data: Data, to url: URL) throws {
    let directory = url.deletingLastPathComponent()
    try FileManager.default.createDirectory(
        at: directory,
        withIntermediateDirectories: true,
        attributes: [.posixPermissions: 0o700]
    )
    try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
    try data.write(to: url, options: [.atomic])
    try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
}

func quarantinePrivateArtifact(at url: URL, id: String) throws -> URL {
    let destination = url
        .deletingLastPathComponent()
        .appendingPathComponent("\(url.lastPathComponent).corrupt-\(id)")
    try FileManager.default.moveItem(at: url, to: destination)
    try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: destination.path)
    return destination
}
