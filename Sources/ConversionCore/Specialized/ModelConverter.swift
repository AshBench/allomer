import Foundation

public struct ModelOptions: Codable, Equatable, Sendable {
    public var binaryPLY = true
    public var binarySTL = true
    public var embedTextures = true
    public init() {}
}

enum ModelConverter {
    static let routes: [String: Set<String>] = [
        "3ds": ["fbx", "glb", "ply", "stl"], "dae": ["fbx", "glb", "ply", "stl"],
        "fbx": ["glb", "ply", "stl"], "glb": ["fbx", "ply", "stl"], "gltf": ["fbx", "glb", "ply", "stl"],
        "obj": ["fbx", "glb", "ply", "stl", "usdz"], "ply": ["fbx", "glb", "stl", "usdz"],
        "stl": ["fbx", "glb", "ply", "usdz"], "usda": ["ply", "stl", "usdz"],
        "usdc": ["ply", "stl", "usdz"], "usdz": ["ply", "stl"]
    ]
    static let outputs: Set<String> = ["fbx", "glb", "ply", "stl", "usdz"]

    static func convert(_ input: URL, to output: URL, from source: FileFormat, to target: FileFormat,
                        tool: URL, options: ModelOptions, resourceDirectory: URL) throws -> [OutputResources] {
        guard routes[source.id]?.contains(target.id) == true else {
            throw ConversionError.message("These model formats cannot be converted directly.")
        }
        let assets = "conversion-assets-\(UUID().uuidString)"
        try ExternalTool.run(tool, arguments: [input.path, output.path, source.id, target.id, resourceDirectory.path,
            options.binaryPLY ? "true" : "false", options.binarySTL ? "true" : "false",
            options.embedTextures ? "true" : "false", assets], workDirectory: output.deletingLastPathComponent())
        let version = try FileVersion(output)
        guard version.size > 0, version.size <= 512 * 1024 * 1024 else {
            throw ConversionError.message("The model writer produced an invalid output file.")
        }
        let directory = output.deletingLastPathComponent().appendingPathComponent(assets)
        return FileManager.default.fileExists(atPath: directory.path) ? [try OutputResources(directory: directory)] : []
    }
}
