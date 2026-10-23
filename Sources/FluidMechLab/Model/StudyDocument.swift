import FlowCore
import SwiftUI
import UniformTypeIdentifiers

extension UTType {
    /// `.fmlab` study files. Declared in the app bundle's Info.plist; falls back to plain JSON when
    /// the app runs unbundled (for example from `swift run`).
    static let fluidMechStudy: UTType = {
        if let type = UTType("com.ashif.fluidmechlab.study"), type.isDeclared { return type }
        return .json
    }()
}

/// A study saved on disk as pretty-printed JSON.
struct StudyDocument: FileDocument {
    static var readableContentTypes: [UTType] {
        UTType.fluidMechStudy == .json ? [.json] : [.fluidMechStudy, .json]
    }

    static var writableContentTypes: [UTType] { [.fluidMechStudy] }

    var study: StudyCase

    init(study: StudyCase = StudyCase()) {
        self.study = study
    }

    init(configuration: ReadConfiguration) throws {
        guard let data = configuration.file.regularFileContents else {
            throw CocoaError(.fileReadCorruptFile)
        }
        study = try JSONDecoder().decode(StudyCase.self, from: data)
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return FileWrapper(regularFileWithContents: try encoder.encode(study))
    }
}

/// Plain-text CSV for File ▸ Export.
struct CSVDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.commaSeparatedText] }

    var text: String

    init(text: String = "") {
        self.text = text
    }

    init(configuration: ReadConfiguration) throws {
        text = String(decoding: configuration.file.regularFileContents ?? Data(), as: UTF8.self)
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: Data(text.utf8))
    }
}
