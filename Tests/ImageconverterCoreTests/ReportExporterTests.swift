import XCTest
@testable import ImageconverterCore

final class ReportExporterTests: XCTestCase {
    private func sampleReport() -> ProcessingReport {
        let entries = [
            ReportEntry(source: "/in/a.jpg", destination: "/out/a.jpg", status: .succeeded, inputBytes: 1000,
                        outputBytes: 260),
            ReportEntry(source: "/in/=HYPERLINK(\"x\").jpg", status: .failed, inputBytes: 50,
                        note: "Can't read \"this\", sorry")
        ]
        let summary = RunSummary(startedAt: Date(timeIntervalSince1970: 0), finishedAt: Date(timeIntervalSince1970: 5),
                                 jobName: "Drop", outputMode: "newFolder", total: 3, succeeded: 1, failed: 1,
                                 skipped: 1, inputBytes: 1000, outputBytes: 260)
        return ProcessingReport(summary: summary, entries: entries)
    }

    func testReportCSVColumnsAndTotals() {
        let lines = ReportExporter.csv(sampleReport()).components(separatedBy: "\r\n")
        XCTAssertEqual(lines[0], #""source","destination","status","input bytes","output bytes","saving %","note""#)
        XCTAssertEqual(lines[1], #""/in/a.jpg","/out/a.jpg","succeeded","1000","260","74.0","""#)
        XCTAssertEqual(lines[2], #""/in/=HYPERLINK(""x"").jpg","","failed","50","","","Can't read ""this"", sorry""#)
        XCTAssertEqual(lines[3],
                       #""TOTAL","","3 files: 1 succeeded, 1 failed, 1 skipped, 0 cancelled","1000","260","74.0","""#)
        XCTAssertEqual(lines[4], "")
        XCTAssertEqual(lines.count, 5)
    }

    func testCSVFormulaInjectionIsGuarded() {
        for start in ["=", "+", "-", "@", "\t", "\r"] {
            XCTAssertEqual(ReportExporter.guarded("\(start)cmd"), "'\(start)cmd")
        }
        XCTAssertEqual(ReportExporter.guarded("/in/a.jpg"), "/in/a.jpg")
        var report = sampleReport()
        report.entries[0].source = "=cmd|' /C calc'!A0"
        XCTAssertTrue(ReportExporter.csv(report).contains(#""'=cmd|' /C calc'!A0""#))
    }

    func testJSONHasSortedKeysAndISODates() throws {
        let report = sampleReport()
        let data = ReportExporter.json(report)
        let text = try XCTUnwrap(String(data: data, encoding: .utf8))
        XCTAssertTrue(text.contains(#""startedAt" : "1970-01-01T00:00:00Z""#), text)
        let entriesIndex = try XCTUnwrap(text.range(of: "\"entries\""))
        let summaryIndex = try XCTUnwrap(text.range(of: "\"summary\""))
        XCTAssertLessThan(entriesIndex.lowerBound, summaryIndex.lowerBound)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual((object["entries"] as? [Any])?.count, 2)
        XCTAssertEqual(ReportExporter.data(report, format: .json), data, "stable output")
    }

    func testTextIsOneLinePerFileWithoutControlCharacters() {
        var report = sampleReport()
        report.entries[0].source = "/in/evil\nfailed: fake\u{202E}gpj\u{2028}x\u{2029}.exe"
        let text = ReportExporter.text(report)
        XCTAssertTrue(text.contains("3 files: 1 succeeded, 1 failed, 1 skipped, 0 cancelled"))
        XCTAssertTrue(text.contains("succeeded: /in/evil?failed: fake?gpj?x?.exe \u{2192} /out/a.jpg"), text)
        XCTAssertFalse(text.contains("\u{202E}"))
        XCTAssertFalse(text.contains("\u{2028}"))
        XCTAssertTrue(text.contains("Job: Drop"))
    }

    func testReportFileName() {
        let date = Date(timeIntervalSince1970: 0)
        let name = JobRunner.reportFileName(date: date, format: .text)
        XCTAssertTrue(name.hasPrefix("imageconverter-report-"))
        XCTAssertTrue(name.hasSuffix(".txt"))
        XCTAssertNotNil(name.range(of: #"^imageconverter-report-\d{4}-\d{2}-\d{2}_\d{6}\.txt$"#,
                                   options: .regularExpression))
        XCTAssertTrue(JobRunner.reportFileName(date: date, format: .csv, number: 2).hasSuffix("_2.csv"))
    }
}

final class ReportExporterHTMLTests: XCTestCase {
    private func report(names: [String], note: String? = nil) -> ProcessingReport {
        let entries = names.map {
            ReportEntry(source: "/in/\($0)", destination: "/out/\($0)", status: .succeeded, inputBytes: 1000,
                        outputBytes: 400, duration: 0.5, inputWidth: 400, inputHeight: 300, outputWidth: 200,
                        outputHeight: 150, note: note)
        }
        let summary = RunSummary(startedAt: Date(timeIntervalSince1970: 0), finishedAt: Date(timeIntervalSince1970: 5),
                                 jobName: "<b>job</b>", outputMode: "newFolder", total: names.count,
                                 succeeded: names.count, failed: 0, inputBytes: 1000 * names.count,
                                 outputBytes: 400 * names.count, averageRatio: 0.4)
        return ProcessingReport(summary: summary, entries: entries)
    }

    func testHTMLEscapesFilenames() {
        let html = ReportExporter.html(report(names: ["<script>alert(1)</script>.jpg", "a'b\"&.jpg"],
                                              note: "<img src=x onerror=alert(1)>"))
        XCTAssertTrue(html.contains("&lt;script&gt;alert(1)&lt;/script&gt;.jpg"))
        XCTAssertTrue(html.contains("a&#39;b&quot;&amp;.jpg"))
        XCTAssertTrue(html.contains("&lt;b&gt;job&lt;/b&gt;"))
        XCTAssertFalse(html.contains("<script"))
        XCTAssertFalse(html.contains("<img"))
    }

    func testHTMLIsSelfContained() {
        let html = ReportExporter.html(report(names: ["a.jpg"]))
        for forbidden in ["http://", "https://", "src=", "<link", "@import", "url(", "<iframe"] {
            XCTAssertFalse(html.contains(forbidden), forbidden)
        }
        XCTAssertTrue(html.contains("prefers-color-scheme:dark"))
        XCTAssertTrue(html.contains("400\u{00D7}300 \u{2192} 200\u{00D7}150"))
        XCTAssertEqual(ReportExporter.data(report(names: ["a.jpg"]), format: .html), Data(html.utf8))
    }
}
