import CoreGraphics
import Foundation

/// Builds page text from Vision lines without losing table rows.
///
/// Vision reports every table cell as its own line and usually reads a table
/// one column at a time, so in plainly joined text a label and its amount end
/// up far apart. This keeps Vision's reading order for ordinary text and puts
/// the cells of one table row on one line, left to right.
enum TableRowTextAssembler {
    static let cellSeparator = " | "

    static func text(for lines: [TextLine]) -> String {
        guard lines.count > 1, lines.allSatisfy({ isUsable($0.boundingBox) }) else {
            return lines.map(\.text).joined(separator: "\n")
        }

        var rows: [[Int]] = []
        var rowOfLine = [Int](repeating: 0, count: lines.count)
        for index in lines.indices.sorted(by: { isHigherOnPage(lines[$0].boundingBox, lines[$1].boundingBox, $0, $1) }) {
            let box = lines[index].boundingBox
            if let row = rows.firstIndex(where: { members in
                members.contains { sitsBeside(box, lines[$0].boundingBox) }
            }) {
                rows[row].append(index)
                rowOfLine[index] = row
            } else {
                rowOfLine[index] = rows.count
                rows.append([index])
            }
        }

        let isTableRow = rows.map { members in
            members.count > 1 && looksTabular(members.map { lines[$0].text })
        }
        var emitted = [Bool](repeating: false, count: rows.count)
        var output: [String] = []
        output.reserveCapacity(lines.count)
        // Walk in Vision's own order so prose and multi-column pages read as before.
        for index in lines.indices {
            let row = rowOfLine[index]
            guard isTableRow[row] else {
                output.append(lines[index].text)
                continue
            }
            guard !emitted[row] else {
                continue
            }
            emitted[row] = true
            let cells = rows[row].sorted { lhs, rhs in
                let left = lines[lhs].boundingBox.minX
                let right = lines[rhs].boundingBox.minX
                return left == right ? lhs < rhs : left < right
            }
            output.append(cells.map { lines[$0].text }.joined(separator: cellSeparator))
        }
        return output.joined(separator: "\n")
    }

    private static func isUsable(_ box: CGRect) -> Bool {
        [box.minX, box.minY, box.width, box.height].allSatisfy(\.isFinite) && box.width > 0 && box.height > 0
    }

    private static func isHigherOnPage(_ lhs: CGRect, _ rhs: CGRect, _ lhsIndex: Int, _ rhsIndex: Int) -> Bool {
        // Vision geometry has its origin at the bottom-left corner.
        if lhs.midY != rhs.midY {
            return lhs.midY > rhs.midY
        }
        if lhs.minX != rhs.minX {
            return lhs.minX < rhs.minX
        }
        return lhsIndex < rhsIndex
    }

    /// Two lines are cells of one row when they overlap vertically, are of
    /// comparable height, and stand side by side rather than on top of each other.
    private static func sitsBeside(_ lhs: CGRect, _ rhs: CGRect) -> Bool {
        let smallerHeight = min(lhs.height, rhs.height)
        let largerHeight = max(lhs.height, rhs.height)
        guard largerHeight / smallerHeight <= 2.5 else {
            return false
        }
        let verticalOverlap = min(lhs.maxY, rhs.maxY) - max(lhs.minY, rhs.minY)
        guard verticalOverlap / smallerHeight >= 0.5 else {
            return false
        }
        let horizontalOverlap = min(lhs.maxX, rhs.maxX) - max(lhs.minX, rhs.minX)
        return horizontalOverlap / min(lhs.width, rhs.width) < 0.5
    }

    /// A row is treated as a table row when it carries a short value cell
    /// (an amount, quantity, percentage or lone symbol) or when every cell is
    /// short, as in a header row. Two long lines side by side are two columns
    /// of prose and are left alone.
    private static func looksTabular(_ cells: [String]) -> Bool {
        var everyCellIsShort = true
        for cell in cells {
            let words = cell.split(whereSeparator: \.isWhitespace)
            guard words.count <= 4 else {
                everyCellIsShort = false
                continue
            }
            if cell.contains(where: \.isNumber) || !cell.contains(where: \.isLetter) {
                return true
            }
        }
        return everyCellIsShort
    }
}
