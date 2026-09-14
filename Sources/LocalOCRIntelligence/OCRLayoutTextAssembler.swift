import Foundation
import LocalOCRService

enum OCRLayoutTextAssembler {
    static func text(for lines: [OCRLineResponse], fallback: String) -> String {
        guard !lines.isEmpty else {
            return fallback
        }

        let layoutLines = lines.map(LayoutLine.init)
        guard layoutLines.allSatisfy(\.hasValidNormalizedGeometry) else {
            return fallback
        }

        var rows: [[LayoutLine]] = []
        for line in layoutLines.sorted(by: sortsAsHigherRow) {
            if let rowIndex = rows.firstIndex(where: { sharesRow(line, with: $0) }) {
                rows[rowIndex].append(line)
            } else {
                rows.append([line])
            }
        }

        let assembled = rows
            .map { row in
                row.sorted(by: sortsFromLeftToRight)
                    .map(\.text)
                    .joined(separator: " | ")
            }
            .joined(separator: "\n")

        return assembled.isEmpty ? fallback : assembled
    }

    private static func sharesRow(_ line: LayoutLine, with row: [LayoutLine]) -> Bool {
        row.contains { other in
            let intersection = min(line.maxY, other.maxY) - max(line.y, other.y)
            let smallerHeight = min(line.height, other.height)
            return intersection / smallerHeight >= 0.5
        }
    }

    private static func sortsAsHigherRow(_ lhs: LayoutLine, _ rhs: LayoutLine) -> Bool {
        if lhs.verticalMidpoint != rhs.verticalMidpoint {
            return lhs.verticalMidpoint > rhs.verticalMidpoint
        }
        return sortsFromLeftToRight(lhs, rhs)
    }

    private static func sortsFromLeftToRight(_ lhs: LayoutLine, _ rhs: LayoutLine) -> Bool {
        if lhs.x != rhs.x {
            return lhs.x < rhs.x
        }
        if lhs.y != rhs.y {
            return lhs.y > rhs.y
        }
        if lhs.width != rhs.width {
            return lhs.width < rhs.width
        }
        if lhs.height != rhs.height {
            return lhs.height < rhs.height
        }
        if lhs.text != rhs.text {
            return lhs.text < rhs.text
        }
        return lhs.confidence < rhs.confidence
    }
}

private struct LayoutLine {
    let text: String
    let confidence: Float
    let x: Double
    let y: Double
    let width: Double
    let height: Double

    init(_ line: OCRLineResponse) {
        text = line.text
        confidence = line.confidence
        x = line.x
        y = line.y
        width = line.width
        height = line.height
    }

    var maxX: Double { x + width }
    var maxY: Double { y + height }
    var verticalMidpoint: Double { y + height / 2 }

    var hasValidNormalizedGeometry: Bool {
        [x, y, width, height].allSatisfy(\.isFinite)
            && x >= 0
            && y >= 0
            && width > 0
            && height > 0
            && maxX <= 1
            && maxY <= 1
    }
}
