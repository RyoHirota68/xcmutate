/// Every name that is derived from the name of the tool, in one place.
///
/// Renaming the tool means changing the values here, plus the things Swift cannot derive from a constant
/// (the package, product and target names in `Package.swift`, the `Sources/xcmutate` directory, the
/// documentation, the fixture and the tests that spell the names out).
public enum ToolNaming {
    /// The executable name; also the prefix of progress and error lines and the name written into reports.
    public static let toolName = "xcmutate"
    /// Prefix of every identifier that the embedded helper declares in a mutated file.
    public static let helperTypeName = "__xcmutate"
    /// Prefix of the environment variables that the helper and `--prepare` commands read.
    public static let environmentPrefix = "XCMUTATE_"
    /// Prefix of disable comments (`// xcmutate:disable-next-line`).
    public static let commentMarker = toolName + ":"
    /// First line of the helper appended to every mutated file.
    public static let helperMarker = "// \(toolName): generated helper. Do not edit."
    /// Config file looked up in `--root`.
    public static let configFileName = "xcmutate.yml"
    /// Accepted (equivalent) mutants file looked up in `--root`.
    public static let acceptedFileName = "xcmutate.accepted.json"
    /// Marker file written into every work directory.
    public static let workDirectoryMarkerFileName = toolName + "-workdir.json"
    /// Directory under `~/Library/Caches` that holds the default work directories.
    public static let cacheDirectoryName = toolName
}
