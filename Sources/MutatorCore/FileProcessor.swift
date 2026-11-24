/// Processing result for one file (input text → output text + list of mutants).
public struct FileResult: Sendable {
    public var file: String
    public var instrumented: String
    public var mutants: [Mutant]
    public var ignored: [IgnoredMutant]
    /// Number of mutants dropped as outside the diff.
    public var outOfDiffCount: Int
    public var skippedReason: String?
    public var verification: VerificationResult
    public var warnings: [GenerationWarning] = []
}

/// A pure function that completes "parse → discover → narrow by diff → assign IDs → instrument → static verification" within one file.
///
/// The syntax tree is created and discarded in here. When processing several files, pass the ID following the previous file's last ID
/// as `firstID` so that IDs are sequential across files.
public struct FileProcessor: Sendable {
    public var generator: MutantGenerator

    public init(options: GeneratorOptions = GeneratorOptions()) {
        generator = MutantGenerator(options: options)
    }

    /// - Parameters:
    ///   - changedLines: Line ranges of the diff. If `nil`, the whole file is targeted.
    public func process(source: String, file: String, firstID: Int, changedLines: [ClosedRange<Int>]? = nil) -> FileResult {
        let generated = generator.generate(source: source, filePath: file, changedLines: changedLines)
        var mutants = generated.mutants
        let outOfDiff = generated.outOfDiffCount
        mutants = mutants.enumerated().map { index, m in
            var m = m
            m.id = firstID + index
            return m
        }
        let instrumented = Instrumenter.instrument(source: source, mutants: mutants)
        let verification = InstrumentationVerifier.verify(original: source, instrumented: instrumented, mutants: mutants)
        let ignored = generated.ignored
        return FileResult(
            file: file, instrumented: instrumented, mutants: mutants, ignored: ignored,
            outOfDiffCount: outOfDiff, skippedReason: generated.skippedReason, verification: verification,
            warnings: generated.warnings)
    }
}
