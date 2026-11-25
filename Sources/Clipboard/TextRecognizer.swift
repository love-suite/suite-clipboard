import AppKit
import ClipboardCore
import Vision

/// The text in a picture, read on this Mac with Vision (nothing leaves it), so a screenshot can be
/// found by what it says.
enum TextRecognizer {
    private static let queue = DispatchQueue(label: "local.suite.clipboard.text", qos: .utility)

    /// Calls back on the main thread, with an empty string when the picture has no text.
    static func text(in snapshot: PasteboardSnapshot, completion: @escaping (String) -> Void) {
        guard let data = PasteboardType.images.lazy.compactMap({ snapshot.data($0) }).first else {
            completion("")
            return
        }
        queue.async {
            let text = recognize(data)
            DispatchQueue.main.async { completion(text) }
        }
    }

    private static func recognize(_ data: Data) -> String {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { return "" }
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true
        if #available(macOS 13, *) { request.automaticallyDetectsLanguage = true }
        do {
            try VNImageRequestHandler(cgImage: image).perform([request])
        } catch {
            return ""
        }
        return (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }.joined(separator: "\n")
    }
}
