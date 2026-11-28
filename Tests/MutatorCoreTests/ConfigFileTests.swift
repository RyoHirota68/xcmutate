import Foundation
import Testing
@testable import MutatorCore
@testable import MutatorRunner

/// The config file in YAML (`xcmutate.yml`), the JSON file of earlier versions, and what `init` writes.
@Suite("Config file: YAML and JSON")
struct ConfigFileTests {
    static func read(_ yaml: String) throws -> [String: Any] {
        try #require(try ConfigFile.yamlValue(yaml) as? [String: Any])
    }

    /// YAML 1.1 would read `yes`, `no`, `on` and `off` as booleans and `0x10` or `1_000` as numbers; the file is read
    /// with YAML 1.2's JSON schema, so they stay strings and a key of another type rejects them.
    @Test func scalarsAreReadWithTheTypesOfJSON() throws {
        let value = try Self.read("""
        a: yes
        b: no
        c: on
        d: off
        e: true
        f: false
        g: 3h
        h: 0.15
        i: 08
        j: 12
        k: ~
        l:
        m: "true"
        n: '12'
        o: 0x10
        p: 1_000
        q: -3
        r: 1e3
        s: null
        t: True
        u: !!str 12
        """)
        #expect(value["a"] as? String == "yes" && value["b"] as? String == "no" && value["c"] as? String == "on" && value["d"] as? String == "off")
        #expect(value["e"] as? Bool == true && value["f"] as? Bool == false && value["t"] as? String == "True")
        #expect(value["g"] as? String == "3h" && value["h"] as? Double == 0.15 && value["i"] as? String == "08" && value["j"] as? Int == 12)
        #expect(value["k"] is NSNull && value["l"] is NSNull && value["s"] is NSNull)
        #expect(value["m"] as? String == "true" && value["n"] as? String == "12" && value["u"] as? String == "12")
        #expect(value["o"] as? String == "0x10" && value["p"] as? String == "1_000" && value["q"] as? Int == -3 && value["r"] as? Double == 1000)
        #expect { try ConfigFile.yamlValue("a: 1\na: 2\n") } throws: { "\($0)".contains("duplicated key") }
        // An alias is the value of its anchor
        #expect((try Self.read("a: &x [1]\nb: *x\n"))["b"] as? [Int] == [1])
        #expect(throws: ConfigFile.Failure.self) { try ConfigFile.yamlValue("a: !!binary aGVsbG8=\n") }
    }

    /// The run options in YAML go through the same checks as the command line: a value of YAML 1.1 that looks like a
    /// boolean is not one, `none` for confirmKills is refused, and errors and warnings say where the keys are documented.
    @Test func runOptionsInYAMLAreCheckedLikeTheCommandLine() throws {
        try withTemporaryDirectory { directory in
            let file = directory.appendingPathComponent("xcmutate.yml")
            func expand(_ text: String, profile: String? = nil, given: [String] = ["run"]) throws -> RunProfile.Expansion {
                try text.write(to: file, atomically: true, encoding: .utf8)
                return try RunProfile.expand(configAt: file, profile: profile, given: given)
            }
            let fine = try expand("""
            # a comment
            run:
              scheme: App          # the app
              destination: [id=A, id=B]
              sharedProcess: auto
              failUnder: 80
              timeLimit: 3h
              workers: 2
            profiles:
              pr: {since: origin/main, selectTests: reach, failOnSurvived: true}
            """, profile: "pr")
            #expect(fine.arguments == ["--destination", "id=A", "--destination", "id=B", "--fail-on-survived", "--fail-under", "80", "--scheme", "App",
                                       "--select-tests", "reach", "--shared-process-auto", "--since", "origin/main", "--time-limit", "3h", "--workers", "2"])
            #expect { try expand("run:\n  failOnSurvived: yes\n") } throws: { "\($0)".contains("must be true or false") && "\($0)".contains(ConfigFile.runOptionsDocumentation) }
            #expect { try expand("run:\n  sharedProcess: on\n") } throws: { "\($0)".contains("must be true, false or \"auto\"") }
            #expect { try expand("run:\n  scheme: 12\n") } throws: { "\($0)".contains("must be a string") }
            #expect { try expand("run:\n  workers: \"2\"\n") } throws: { "\($0)".contains("must be a number") }
            #expect { try expand("run:\n  confirmKills: none\n") } throws: { "\($0)".contains("makes verdicts weaker") && "\($0)".contains(ConfigFile.runOptionsDocumentation) }
            #expect { try expand("run: {}\n", profile: "nightly") } throws: { "\($0)".contains("has no such profile") && "\($0)".contains(ConfigFile.runOptionsDocumentation) }
            let unknown = try expand("run:\n  schema: App\n  _why: x\n")
            #expect(unknown.warnings.count == 2 && unknown.warnings.allSatisfy { $0.contains(ConfigFile.runOptionsDocumentation) })
            // In JSON, `_` keys are explanations, as before
            let json = directory.appendingPathComponent("xcmutate.config.json")
            try #"{"run": {"scheme": "App", "_why": {"scheme": "the only one"}}}"#.write(to: json, atomically: true, encoding: .utf8)
            #expect(try RunProfile.expand(configAt: json, profile: nil, given: ["run"]).warnings.isEmpty)
        }
    }

    /// The other keys are read from YAML as from JSON; in YAML a `_` key is an unknown key (comments are the place for
    /// explanations), in JSON it is an explanation.
    @Test func theOtherKeysAreReadFromYAMLAndJSON() throws {
        try withTemporaryDirectory { directory in
            let yaml = directory.appendingPathComponent("xcmutate.yml")
            try """
            # Calls that only log
            aridCalls: [Analytics.track]
            exclude:
              - "Generated/**"
              - "!Generated/Kept.swift"
            maxSwitchesPerExpression: 8
            _note: something
            exclude-typo: x
            """.write(to: yaml, atomically: true, encoding: .utf8)
            let config = try MutatorConfig.load(yaml)
            #expect(config.aridCalls == ["Analytics.track"] && config.exclude == ["Generated/**", "!Generated/Kept.swift"] && config.maxSwitchesPerExpression == 8)
            #expect(config.loadWarnings.count == 2 && config.loadWarnings.contains { $0.contains("`_note`") && $0.contains("comments") })
            try "maxSwitchesPerExpression: yes\n".write(to: yaml, atomically: true, encoding: .utf8)
            #expect(throws: MutatorConfig.ConfigError.self) { try MutatorConfig.load(yaml) }
            try "- a\n- b\n".write(to: yaml, atomically: true, encoding: .utf8)
            #expect { try MutatorConfig.load(yaml) } throws: { "\($0)".contains("mapping") }
            try "a: [1\n".write(to: yaml, atomically: true, encoding: .utf8)
            #expect { try MutatorConfig.load(yaml) } throws: { "\($0)".contains("not valid YAML") }
            let json = directory.appendingPathComponent("other.json")
            try #"{"exclude": ["A/**"], "_written": "by init"}"#.write(to: json, atomically: true, encoding: .utf8)
            let fromJSON = try MutatorConfig.load(json)
            #expect(fromJSON.exclude == ["A/**"] && fromJSON.loadWarnings.isEmpty)
        }
    }

    /// The file at the root: `xcmutate.yml`, or the JSON file of earlier versions; two of them stop the command with
    /// both paths, so that which one is read is never a silent choice.
    @Test func theFileAtTheRootIsFoundAndTwoAreRefused() throws {
        try withTemporaryDirectory { root in
            #expect(try ConfigFile.locate(root: root).lastPathComponent == "xcmutate.yml")
            try "{}".write(to: root.appendingPathComponent("xcmutate.config.json"), atomically: true, encoding: .utf8)
            #expect(try ConfigFile.locate(root: root).lastPathComponent == "xcmutate.config.json")
            try "exclude: []".write(to: root.appendingPathComponent("xcmutate.yml"), atomically: true, encoding: .utf8)
            #expect { try ConfigFile.locate(root: root) } throws: { error in
                let text = "\(error)"
                return text.contains("xcmutate.yml") && text.contains("xcmutate.config.json") && text.contains("init --force")
            }
            try FileManager.default.removeItem(at: root.appendingPathComponent("xcmutate.config.json"))
            try "".write(to: root.appendingPathComponent("xcmutate.yaml"), atomically: true, encoding: .utf8)
            #expect(throws: ConfigFile.Ambiguous.self) { try ConfigFile.locate(root: root) }
        }
    }

    static func recommendation() -> ProjectSetup.Recommendation {
        var facts = InitAndTimingTests.facts()
        facts.defaultBranch = "origin/main"
        facts.buildArguments = ["-quiet"]
        facts.fileDestination = "platform=iOS Simulator,name=iPhone Duo,OS=27.2"
        return ProjectSetup.recommend(facts: facts, plain: InitAndTimingTests.trial(seconds: 140), fast: InitAndTimingTests.trial(seconds: 100, startup: 20),
                                      fastOptions: InitAndTimingTests.fastOptions)
    }

    /// What init writes reads back as what it chose; the reasons are comments, the gates commented-out keys, and the
    /// file starts with where its keys are documented.
    @Test func theYAMLThatInitWritesReadsBackAsItsChoices() throws {
        let recommendation = Self.recommendation()
        let text = ProjectSetup.yamlDocument(recommendation, existingText: nil, carried: ["exclude": ["Vendor/**", "!Vendor/Kept.swift"], "aridCalls": ["log \"x\"\\y"]])
        let read = try Self.read(text)
        #expect(ProjectSetup.sameValue(read["run"]!, ProjectSetup.withoutExplanations(recommendation.run)))
        #expect(ProjectSetup.sameValue(read["profiles"]!, ProjectSetup.withoutExplanations(recommendation.profiles)))
        #expect(read["exclude"] as? [String] == ["Vendor/**", "!Vendor/Kept.swift"] && read["aridCalls"] as? [String] == ["log \"x\"\\y"])
        #expect(Set(read.keys) == ["run", "profiles", "exclude", "aridCalls"])
        #expect(text.hasPrefix("# The config file of xcmutate. The run options (run, profiles): \(ConfigFile.runOptionsDocumentation)"))
        #expect(text.contains("blob/v\(ToolInfo.version)/docs/usage.md"))
        #expect(text.contains("    # failOnSurvived: true") && text.contains("    # stopWhenGateDecided: true"))
        #expect(text.contains("  # the scheme used for the trials\n  scheme: \"App\""))
        #expect(!text.contains("_why") && !text.contains("_gateExamples") && !text.contains("_estimate"))
    }

    /// An existing YAML file keeps its other keys and its comments, and its run options are replaced; a file that
    /// cannot be edited by lines (flow style) is written anew from its values. A JSON file of an earlier version is
    /// replaced by `xcmutate.yml` with its settings; a `.json` file named with --config stays JSON.
    @Test func initKeepsTheFileItWritesInto() throws {
        let recommendation = Self.recommendation()
        try withTemporaryDirectory { root in
            let yaml = root.appendingPathComponent("xcmutate.yml")
            try """
            # Our settings
            exclude:
              - "Vendor/**"   # third-party code
            run:
              scheme: Old
              destination: id=X

            # Calls that only log
            aridCalls: [Log.debug]
            profiles:
              pr: {since: main}
            """.write(to: yaml, atomically: true, encoding: .utf8)
            let output = try ProjectSetup.output(recommendation, target: yaml, legacy: nil)
            #expect(output.file == yaml && output.replaces == nil && !output.commentsLost)
            #expect(output.text.hasPrefix("# The config file of xcmutate"))
            #expect(output.text.contains("# Our settings") && output.text.contains("# third-party code") && output.text.contains("# Calls that only log\naridCalls: [Log.debug]"))
            #expect(!output.text.contains("scheme: Old") && !output.text.contains("since: main"))
            let read = try Self.read(output.text)
            #expect(read["exclude"] as? [String] == ["Vendor/**"] && read["aridCalls"] as? [String] == ["Log.debug"])
            #expect(ProjectSetup.sameValue(read["run"]!, ProjectSetup.withoutExplanations(recommendation.run)))

            try #"{exclude: ["A/**"], run: {scheme: Old}}"#.write(to: yaml, atomically: true, encoding: .utf8)
            let flow = try ProjectSetup.output(recommendation, target: yaml, legacy: nil)
            #expect(flow.commentsLost)
            let flowRead = try Self.read(flow.text)
            #expect(flowRead["exclude"] as? [String] == ["A/**"] && ProjectSetup.sameValue(flowRead["profiles"]!, ProjectSetup.withoutExplanations(recommendation.profiles)))
            try FileManager.default.removeItem(at: yaml)

            let json = root.appendingPathComponent("xcmutate.config.json")
            try #"{"exclude": ["A/**"], "enabledOperators": ["arithmetic"], "run": {"scheme": "Old"}, "_written": "by init 0.14"}"#.write(to: json, atomically: true, encoding: .utf8)
            let targets = try ProjectSetup.targets(given: nil, root: root)
            #expect(targets.target == yaml && targets.legacy == json)
            let moved = try ProjectSetup.output(recommendation, target: targets.target, legacy: targets.legacy)
            #expect(moved.file == yaml && moved.replaces == json)
            let movedRead = try Self.read(moved.text)
            #expect(Set(movedRead.keys) == ["exclude", "enabledOperators", "run", "profiles"] && movedRead["enabledOperators"] as? [String] == ["arithmetic"])
            #expect(moved.text.contains("# From xcmutate.config.json: _written: by init 0.14"))
            let kept = try ProjectSetup.output(recommendation, target: json, legacy: nil)
            #expect(kept.file == json && kept.replaces == nil && kept.text.contains("\"_why\""))
            #expect(try ProjectSetup.targets(given: json, root: root).legacy == nil)
        }
        // Lines of the top-level keys and what belongs to them
        let text = "a: 1\nrun:\n  x: 1\n  # inside\n\n# about b\nb: 2\nprofiles:\n  p: {}\n"
        #expect(ConfigFile.removingTopLevel(["run", "profiles"], from: text) == "a: 1\n\n# about b\nb: 2\n")
    }

    /// A YAML file and the JSON file of an earlier version at the root: `run` stops with both (and says how to move
    /// one into the other), and init can do that move: the YAML file keeps its keys and gets those of the JSON file
    /// that it does not have. The same when --config names a YAML file. Two YAML files stop init too.
    @Test func initMovesTheJSONFileIntoTheYAMLFileBesideIt() throws {
        let recommendation = Self.recommendation()
        try withTemporaryDirectory { root in
            let yaml = root.appendingPathComponent("xcmutate.yml")
            let json = root.appendingPathComponent("xcmutate.config.json")
            try "# ours\nexclude: [\"Mine/**\"]\n".write(to: yaml, atomically: true, encoding: .utf8)
            try #"{"exclude": ["Old/**"], "aridCalls": ["Log"], "profiles": {"team": {"since": "main"}}}"#.write(to: json, atomically: true, encoding: .utf8)
            #expect { try ConfigFile.locate(root: root) } throws: { "\($0)".contains("init --force` moves its settings into xcmutate.yml") }
            let targets = try ProjectSetup.targets(given: nil, root: root)
            #expect(targets.target == yaml && targets.legacy == json)
            let output = try ProjectSetup.output(recommendation, target: targets.target, legacy: targets.legacy)
            let read = try Self.read(output.text)
            #expect(read["exclude"] as? [String] == ["Mine/**"] && read["aridCalls"] as? [String] == ["Log"] && output.text.contains("# ours"))
            #expect((read["profiles"] as? [String: Any])?["team"] == nil && output.replaces == json)
            // The trials read the settings of both, the YAML file's first
            let settings = try ProjectSetup.settings(target: yaml, legacy: json)
            #expect(settings["exclude"] as? [String] == ["Mine/**"] && settings["aridCalls"] as? [String] == ["Log"])
            // --config naming the YAML file moves the JSON file too
            let named = try ProjectSetup.targets(given: yaml, root: root)
            #expect(named.target == yaml && named.legacy == json)
            try "".write(to: root.appendingPathComponent("xcmutate.yaml"), atomically: true, encoding: .utf8)
            #expect { try ProjectSetup.targets(given: nil, root: root) } throws: { "\($0)".contains("keep one of xcmutate.yml and xcmutate.yaml") }
        }
    }

    /// Writing again replaces what init wrote before (its header with the links of its version, its paragraph with the
    /// estimate), instead of adding more of them.
    @Test func writingAgainReplacesWhatInitWroteBefore() throws {
        let recommendation = Self.recommendation()
        try withTemporaryDirectory { root in
            let yaml = root.appendingPathComponent("xcmutate.yml")
            let old = ProjectSetup.yamlDocument(recommendation, existingText: "# ours\nexclude: []\n", carried: [:])
                .replacingOccurrences(of: "blob/v\(ToolInfo.version)/", with: "blob/v0.0.1/")
            try old.write(to: yaml, atomically: true, encoding: .utf8)
            var text = old
            for _ in 0..<3 {
                try text.write(to: yaml, atomically: true, encoding: .utf8)
                text = try ProjectSetup.output(recommendation, target: yaml, legacy: nil).text
            }
            #expect(text.components(separatedBy: "# Written by xcmutate init").count == 2)
            #expect(text.components(separatedBy: "# The config file of xcmutate.").count == 2 && !text.contains("v0.0.1"))
            #expect(text.components(separatedBy: "# ours").count == 2)
        }
    }

    /// Merge keys, tags that are not standard or do not agree with the value, and numbers out of range are refused
    /// (`<<` was read as an unknown key, and the gate it was meant to bring went missing); a key whose children are all
    /// commented out is empty; a string key says to quote a number.
    @Test func whatYAMLCouldMakeOfAValueIsRefusedOrSaid() throws {
        for text in ["base: &b {failOnSurvived: true}\nrun:\n  <<: *b\n", "a: !!int x\n", "a: !!int \"12\"\n", "a: !custom 1\n", "a: !!set {x: null}\n",
                     "a: !!omap [x: 1]\n", "a: 99999999999999999999\n", "a: 1e400\n", "a: -1e400\n"] {
            #expect(throws: (any Error).self, "\(text)") { try ConfigFile.yamlValue(text) }
        }
        #expect((try Self.read("a: !!int 12\nb: !!float 1\nc: !!str 12\nd: !!null ~\ne: !!bool true\nf: !!map {x: 1}\ng: !!seq [1]\n\"<<\": 1\n")).count == 8)
        try withTemporaryDirectory { directory in
            let file = directory.appendingPathComponent("xcmutate.yml")
            func expand(_ text: String, profile: String? = nil) throws -> RunProfile.Expansion {
                try text.write(to: file, atomically: true, encoding: .utf8)
                return try RunProfile.expand(configAt: file, profile: profile, given: ["run"])
            }
            #expect(try expand("run:\n  # scheme: App\nprofiles:\n  pr:\n    # since: main\n", profile: "pr").arguments.isEmpty)
            #expect(try expand("profiles:\n", profile: nil).arguments.isEmpty)
            #expect { try expand("run:\n  timeLimit: 90\n") } throws: { "\($0)".contains("must be a string; write it in quotes: timeLimit: \"90\"") }
            #expect { try expand("run:\n  since: 1234567\n") } throws: { "\($0)".contains("since: \"1234567\"") }
            #expect { try expand("run:\n  destination: [12]\n") } throws: { "\($0)".contains("destination: \"12\"") }
            #expect { try expand("run:\n  workers: 1e20\n") } throws: { "\($0)".contains("out of range") }
            #expect { try expand("run:\n  <<: {failOnSurvived: true}\n") } throws: { "\($0)".contains("merge keys") }
            let json = directory.appendingPathComponent("c.json")
            try #"{"run": {"timeLimit": 90}}"#.write(to: json, atomically: true, encoding: .utf8)
            #expect { try RunProfile.expand(configAt: json, profile: nil, given: ["run"]) } throws: { "\($0)".contains(#""timeLimit": "90""#) }
            try #"{"maxSwitchesPerExpression": 1e400}"#.write(to: json, atomically: true, encoding: .utf8)
            #expect(throws: (any Error).self) { try MutatorConfig.load(json) }
        }
    }

    /// The YAML writer: strings are quoted whatever they hold, so that they read back as the same strings.
    @Test func theWriterQuotesEveryString() throws {
        let value: [String: Any] = ["s": ["yes", "no", "on", "3h", "0.15", "08", "~", "null", "a: b", "# c", "- d", "\"q\" \\ \t\n", "日本語", "",
                                          "\u{85}", "\u{2028}\u{2029}", [0xfffe, 0xffff, 0xfdd0, 0x1fffe].map { String(Character(Unicode.Scalar($0)!)) }.joined(), "\u{9f}\u{7f}", "<<"],
                                    "n": 12, "d": 0.5, "b": false, "nested": ["deep": ["x": true]], "empty": [String](), "map": [String: Any]()]
        let text = String(ConfigFile.yaml(value, indent: 0).dropFirst())
        #expect(ProjectSetup.sameValue(try Self.read(text), value))
    }
}
