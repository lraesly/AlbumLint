import Foundation
import os

private let log = Logger(subsystem: "com.albumlint", category: "ExcelExporter")

/// Minimal .xlsx writer. An xlsx file is a ZIP archive containing XML files.
/// This produces a valid spreadsheet that Numbers and Excel can open, with
/// clickable hyperlinks for Apple Music links.
struct ExcelExporter {

    /// A cell value in the spreadsheet.
    enum CellValue {
        case string(String)
        case number(Double)
        case hyperlink(url: String, display: String)
    }

    /// Write rows to an xlsx file. First row is treated as headers.
    static func write(
        headers: [String],
        rows: [[CellValue]],
        sheetName: String = "Sheet1",
        to url: URL
    ) throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("albumlint-xlsx-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        // Collect all unique strings for the shared strings table
        var sharedStrings: [String] = []
        var stringIndex: [String: Int] = [:]

        func registerString(_ s: String) -> Int {
            if let idx = stringIndex[s] { return idx }
            let idx = sharedStrings.count
            sharedStrings.append(s)
            stringIndex[s] = idx
            return idx
        }

        // Register header strings
        let headerIndices = headers.map { registerString($0) }

        // Register row strings and build cell data
        var rowCellData: [[(type: String, value: String)]] = []
        for row in rows {
            var cellData: [(String, String)] = []
            for cell in row {
                switch cell {
                case .string(let s):
                    let idx = registerString(s)
                    cellData.append(("s", "\(idx)"))
                case .number(let n):
                    cellData.append(("n", "\(n)"))
                case .hyperlink(let url, let display):
                    let idx = registerString(display)
                    // Hyperlinks are stored separately; cell shows the display text
                    cellData.append(("s", "\(idx)|link|\(url)"))
                }
            }
            rowCellData.append(cellData)
        }

        // Build sheet XML
        var sheetXML = """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <worksheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main"
                   xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships">
        <sheetData>
        """

        // Header row
        sheetXML += "<row r=\"1\">"
        for (col, idx) in headerIndices.enumerated() {
            let ref = cellRef(row: 1, col: col)
            sheetXML += "<c r=\"\(ref)\" t=\"s\" s=\"1\"><v>\(idx)</v></c>"
        }
        sheetXML += "</row>\n"

        // Data rows
        var hyperlinks: [(ref: String, url: String)] = []
        for (rowIdx, cellRow) in rowCellData.enumerated() {
            let r = rowIdx + 2
            sheetXML += "<row r=\"\(r)\">"
            for (col, cell) in cellRow.enumerated() {
                let ref = cellRef(row: r, col: col)
                if cell.0 == "s" {
                    if cell.1.contains("|link|") {
                        let parts = cell.1.split(separator: "|link|", maxSplits: 1)
                        let stringIdx = parts[0]
                        let linkURL = String(parts[1])
                        sheetXML += "<c r=\"\(ref)\" t=\"s\" s=\"2\"><v>\(stringIdx)</v></c>"
                        hyperlinks.append((ref, linkURL))
                    } else {
                        sheetXML += "<c r=\"\(ref)\" t=\"s\"><v>\(cell.1)</v></c>"
                    }
                } else {
                    sheetXML += "<c r=\"\(ref)\"><v>\(cell.1)</v></c>"
                }
            }
            sheetXML += "</row>\n"
        }

        sheetXML += "</sheetData>\n"

        // Add hyperlinks section
        if !hyperlinks.isEmpty {
            sheetXML += "<hyperlinks>\n"
            for (i, link) in hyperlinks.enumerated() {
                sheetXML += "<hyperlink ref=\"\(link.ref)\" r:id=\"rLink\(i)\"/>\n"
            }
            sheetXML += "</hyperlinks>\n"
        }

        sheetXML += "</worksheet>"

        // Sheet relationships (for hyperlinks)
        var sheetRels = """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">
        """
        for (i, link) in hyperlinks.enumerated() {
            sheetRels += "<Relationship Id=\"rLink\(i)\" Type=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships/hyperlink\" Target=\"\(xmlEscape(link.url))\" TargetMode=\"External\"/>\n"
        }
        sheetRels += "</Relationships>"

        // Shared strings XML
        var ssXML = """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <sst xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main" count="\(sharedStrings.count)" uniqueCount="\(sharedStrings.count)">
        """
        for s in sharedStrings {
            ssXML += "<si><t>\(xmlEscape(s))</t></si>\n"
        }
        ssXML += "</sst>"

        // Styles XML (bold headers + hyperlink style)
        let stylesXML = """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <styleSheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main">
        <fonts count="3">
            <font><sz val="11"/><name val="Calibri"/></font>
            <font><b/><sz val="11"/><name val="Calibri"/></font>
            <font><u/><sz val="11"/><color rgb="FF0563C1"/><name val="Calibri"/></font>
        </fonts>
        <fills count="2">
            <fill><patternFill patternType="none"/></fill>
            <fill><patternFill patternType="gray125"/></fill>
        </fills>
        <borders count="1">
            <border><left/><right/><top/><bottom/><diagonal/></border>
        </borders>
        <cellStyleXfs count="1">
            <xf numFmtId="0" fontId="0" fillId="0" borderId="0"/>
        </cellStyleXfs>
        <cellXfs count="3">
            <xf numFmtId="0" fontId="0" fillId="0" borderId="0" xfId="0"/>
            <xf numFmtId="0" fontId="1" fillId="0" borderId="0" xfId="0" applyFont="1"/>
            <xf numFmtId="0" fontId="2" fillId="0" borderId="0" xfId="0" applyFont="1"/>
        </cellXfs>
        </styleSheet>
        """

        // Workbook XML
        let workbookXML = """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <workbook xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main"
                  xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships">
        <sheets>
            <sheet name="\(xmlEscape(sheetName))" sheetId="1" r:id="rId1"/>
        </sheets>
        </workbook>
        """

        // Workbook relationships
        let workbookRels = """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">
            <Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/worksheet" Target="worksheets/sheet1.xml"/>
            <Relationship Id="rId2" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/sharedStrings" Target="sharedStrings.xml"/>
            <Relationship Id="rId3" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/styles" Target="styles.xml"/>
        </Relationships>
        """

        // Content types
        let contentTypes = """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types">
            <Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/>
            <Default Extension="xml" ContentType="application/xml"/>
            <Override PartName="/xl/workbook.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.sheet.main+xml"/>
            <Override PartName="/xl/worksheets/sheet1.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.worksheet+xml"/>
            <Override PartName="/xl/sharedStrings.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.sharedStrings+xml"/>
            <Override PartName="/xl/styles.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.styles+xml"/>
        </Types>
        """

        // Top-level relationships
        let topRels = """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">
            <Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" Target="xl/workbook.xml"/>
        </Relationships>
        """

        // Write all files to temp directory
        let xlDir = tempDir.appendingPathComponent("xl")
        let wsDir = xlDir.appendingPathComponent("worksheets")
        let xlRelsDir = xlDir.appendingPathComponent("_rels")
        let wsRelsDir = wsDir.appendingPathComponent("_rels")
        let relsDir = tempDir.appendingPathComponent("_rels")

        for dir in [xlDir, wsDir, xlRelsDir, wsRelsDir, relsDir] {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        }

        try contentTypes.write(to: tempDir.appendingPathComponent("[Content_Types].xml"), atomically: true, encoding: .utf8)
        try topRels.write(to: relsDir.appendingPathComponent(".rels"), atomically: true, encoding: .utf8)
        try workbookXML.write(to: xlDir.appendingPathComponent("workbook.xml"), atomically: true, encoding: .utf8)
        try workbookRels.write(to: xlRelsDir.appendingPathComponent("workbook.xml.rels"), atomically: true, encoding: .utf8)
        try sheetXML.write(to: wsDir.appendingPathComponent("sheet1.xml"), atomically: true, encoding: .utf8)
        try sheetRels.write(to: wsRelsDir.appendingPathComponent("sheet1.xml.rels"), atomically: true, encoding: .utf8)
        try ssXML.write(to: xlDir.appendingPathComponent("sharedStrings.xml"), atomically: true, encoding: .utf8)
        try stylesXML.write(to: xlDir.appendingPathComponent("styles.xml"), atomically: true, encoding: .utf8)

        // ZIP into .xlsx
        // Remove existing file if present
        try? FileManager.default.removeItem(at: url)

        let zipProcess = Process()
        zipProcess.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        zipProcess.arguments = ["-c", "-k", "--sequesterRsrc", "--keepParent", tempDir.path, url.path]

        // ditto with --keepParent adds the parent dir name; we need flat zip
        // Use a different approach: cd into tempDir and zip
        let zipProcess2 = Process()
        zipProcess2.executableURL = URL(fileURLWithPath: "/usr/bin/zip")
        zipProcess2.arguments = ["-r", url.path, "."]
        zipProcess2.currentDirectoryURL = tempDir

        try zipProcess2.run()
        zipProcess2.waitUntilExit()

        guard zipProcess2.terminationStatus == 0 else {
            throw ExportError.zipFailed
        }

        log.info("Exported \(rows.count) rows to \(url.path)")
    }

    // MARK: - Import

    /// Read an xlsx file and return rows as string arrays. Assumes first row is headers.
    static func read(from url: URL) throws -> (headers: [String], rows: [[String]]) {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("albumlint-xlsx-read-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: tempDir) }

        // Unzip
        let unzip = Process()
        unzip.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
        unzip.arguments = ["-o", url.path, "-d", tempDir.path]
        try unzip.run()
        unzip.waitUntilExit()

        // Parse shared strings
        let ssURL = tempDir.appendingPathComponent("xl/sharedStrings.xml")
        let ssData = try Data(contentsOf: ssURL)
        let ssStrings = parseSharedStrings(ssData)

        // Parse sheet
        let sheetURL = tempDir.appendingPathComponent("xl/worksheets/sheet1.xml")
        let sheetData = try Data(contentsOf: sheetURL)
        let allRows = parseSheet(sheetData, sharedStrings: ssStrings)

        guard let headers = allRows.first else {
            return ([], [])
        }
        let dataRows = Array(allRows.dropFirst())
        return (headers, dataRows)
    }

    // MARK: - XML Parsing Helpers

    private static func parseSharedStrings(_ data: Data) -> [String] {
        // Simple regex-based parser for <t>...</t> elements
        let xml = String(data: data, encoding: .utf8) ?? ""
        var strings: [String] = []
        let pattern = try! NSRegularExpression(pattern: "<t[^>]*>(.*?)</t>", options: .dotMatchesLineSeparators)
        let matches = pattern.matches(in: xml, range: NSRange(xml.startIndex..., in: xml))
        for match in matches {
            if let range = Range(match.range(at: 1), in: xml) {
                strings.append(xmlUnescape(String(xml[range])))
            }
        }
        return strings
    }

    private static func parseSheet(_ data: Data, sharedStrings: [String]) -> [[String]] {
        let xml = String(data: data, encoding: .utf8) ?? ""
        var rows: [[String]] = []

        // Parse each <row>
        let rowPattern = try! NSRegularExpression(pattern: "<row[^>]*>(.*?)</row>", options: .dotMatchesLineSeparators)
        let rowMatches = rowPattern.matches(in: xml, range: NSRange(xml.startIndex..., in: xml))

        let cellPattern = try! NSRegularExpression(pattern: "<c[^>]*?(?:t=\"([^\"]*?)\")?[^>]*><v>(.*?)</v></c>", options: .dotMatchesLineSeparators)

        for rowMatch in rowMatches {
            guard let rowRange = Range(rowMatch.range(at: 1), in: xml) else { continue }
            let rowXML = String(xml[rowRange])

            var cells: [String] = []
            let cellMatches = cellPattern.matches(in: rowXML, range: NSRange(rowXML.startIndex..., in: rowXML))

            for cellMatch in cellMatches {
                let type: String
                if let typeRange = Range(cellMatch.range(at: 1), in: rowXML) {
                    type = String(rowXML[typeRange])
                } else {
                    type = "n"
                }

                if let valueRange = Range(cellMatch.range(at: 2), in: rowXML) {
                    let rawValue = String(rowXML[valueRange])
                    if type == "s", let idx = Int(rawValue), idx < sharedStrings.count {
                        cells.append(sharedStrings[idx])
                    } else {
                        cells.append(rawValue)
                    }
                }
            }
            rows.append(cells)
        }
        return rows
    }

    // MARK: - Helpers

    private static func cellRef(row: Int, col: Int) -> String {
        var colStr = ""
        var c = col
        repeat {
            colStr = String(Character(UnicodeScalar(65 + c % 26)!)) + colStr
            c = c / 26 - 1
        } while c >= 0
        return "\(colStr)\(row)"
    }

    private static func xmlEscape(_ string: String) -> String {
        string
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "'", with: "&apos;")
    }

    private static func xmlUnescape(_ string: String) -> String {
        string
            .replacingOccurrences(of: "&amp;", with: "&")
            .replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: "&quot;", with: "\"")
            .replacingOccurrences(of: "&apos;", with: "'")
    }

    enum ExportError: Error, LocalizedError {
        case zipFailed

        var errorDescription: String? {
            switch self {
            case .zipFailed: return "Failed to create .xlsx archive"
            }
        }
    }
}
