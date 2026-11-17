import CoreGraphics
import Foundation
import ImageIO
import Vision

// For every PNG in a folder: each recognized line whose amount runs into non-ASCII letters is read again
// several ways. JSON lines on stdout: the first reading and what each way of re-reading returned.
let folder = URL(fileURLWithPath: CommandLine.arguments[1])
let garbled = try! NSRegularExpression(pattern: #"\d\.\d{0,2}[\p{L}&&[^\x00-\x7F]]"#)

func recognize(_ image: CGImage, region: CGRect? = nil) -> String {
    let request = VNRecognizeTextRequest()
    request.recognitionLevel = .accurate
    request.usesLanguageCorrection = true
    if let region { request.regionOfInterest = region }
    try? VNImageRequestHandler(cgImage: image, options: [:]).perform([request])
    let lines = (request.results ?? []).sorted { $0.boundingBox.minX < $1.boundingBox.minX }
    return lines.compactMap { $0.topCandidates(1).first?.string }.joined(separator: " ")
}

func crop(_ image: CGImage, box: CGRect, padX: CGFloat, padY: CGFloat, scale: CGFloat) -> CGImage? {
    let width = CGFloat(image.width), height = CGFloat(image.height)
    var rect = CGRect(x: box.minX * width, y: (1 - box.maxY) * height, width: box.width * width, height: box.height * height)
    rect = rect.insetBy(dx: -padX * rect.height, dy: -padY * rect.height).intersection(CGRect(x: 0, y: 0, width: width, height: height))
    guard let piece = image.cropping(to: rect.integral) else { return nil }
    // White margin around the piece so the text does not touch the picture's edge.
    let margin = rect.height * scale
    let size = CGSize(width: rect.width * scale + margin * 2, height: rect.height * scale + margin * 2)
    guard let context = CGContext(data: nil, width: Int(size.width), height: Int(size.height), bitsPerComponent: 8,
                                  bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return nil }
    context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
    context.fill(CGRect(origin: .zero, size: size))
    context.interpolationQuality = .high
    context.draw(piece, in: CGRect(x: margin, y: margin, width: rect.width * scale, height: rect.height * scale))
    return context.makeImage()
}

func padded(_ box: CGRect, by share: CGFloat) -> CGRect {
    box.insetBy(dx: -box.height * share, dy: -box.height * share).intersection(CGRect(x: 0, y: 0, width: 1, height: 1))
}

let files = try! FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)
    .filter { $0.pathExtension == "png" }.sorted { $0.path < $1.path }
for file in files {
    guard let source = CGImageSourceCreateWithURL(file as CFURL, nil),
          let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { continue }
    let request = VNRecognizeTextRequest()
    request.recognitionLevel = .accurate
    request.usesLanguageCorrection = true
    try? VNImageRequestHandler(cgImage: image, options: [:]).perform([request])
    for observation in request.results ?? [] {
        guard let top = observation.topCandidates(1).first?.string else { continue }
        guard garbled.firstMatch(in: top, range: NSRange(location: 0, length: (top as NSString).length)) != nil else { continue }
        let box = observation.boundingBox
        var readings: [String: String] = [:]
        readings["region tight"] = recognize(image, region: padded(box, by: 0.15))
        readings["region wide"] = recognize(image, region: padded(box, by: 1.0))
        for (name, padX, padY, scale) in [("crop x2", 0.3, 0.3, 2.0), ("crop x3", 0.3, 0.3, 3.0), ("crop x4", 0.3, 0.3, 4.0),
                                          ("crop x3 tight", 0.05, 0.1, 3.0), ("crop x3 wide", 1.5, 0.6, 3.0)] as [(String, CGFloat, CGFloat, CGFloat)] {
            if let piece = crop(image, box: box, padX: padX, padY: padY, scale: scale) {
                readings[name] = recognize(piece)
            }
        }
        let record: [String: Any] = ["file": file.lastPathComponent, "top": top, "readings": readings]
        print(String(decoding: try! JSONSerialization.data(withJSONObject: record), as: UTF8.self))
    }
}
