import Foundation
import XCTest
@testable import AutoThemeSwitcherCore

final class JSONCEditorTests: XCTestCase {
    func testRejectsInvalidJSONCAndDuplicateTargetKey() throws {
        XCTAssertThrowsError(try JSONCEditor("{ \"a\": 1,, }"))

        var duplicate = try JSONCEditor("""
        {
          "workbench.colorTheme": "A",
          "workbench.colorTheme": "B",
        }
        """)
        XCTAssertThrowsError(try duplicate.setRootString("Light Modern", forKey: "workbench.colorTheme")) { error in
            guard case JSONCEditorError.duplicateKey(path: "$", key: "workbench.colorTheme") = error else {
                return XCTFail("unexpected error: \(error)")
            }
        }
    }

    func testLocalEditsPreserveBOMCRLFCommentsAndTrailingComma() throws {
        let source = "{\r\n  // keep this comment\r\n  \"workbench.colorTheme\": \"Dark Modern\",\r\n  \"untouched\": { \"x\": 1, },\r\n}\r\n"
        var data = Data([0xEF, 0xBB, 0xBF])
        data.append(Data(source.utf8))
        var editor = try JSONCEditor(data: data)

        try editor.setRootString("Light Modern", forKey: "workbench.colorTheme")
        try editor.setRootBoolean(false, forKey: "window.autoDetectColorScheme")

        XCTAssertTrue(editor.hasUTF8BOM)
        XCTAssertTrue(editor.source.contains("// keep this comment\r\n"))
        XCTAssertTrue(editor.source.contains("\"untouched\": { \"x\": 1, },"))
        XCTAssertTrue(editor.source.hasSuffix("}\r\n"))
        XCTAssertFalse(editor.source.replacingOccurrences(of: "\r\n", with: "").contains("\n"))
        XCTAssertEqual(try editor.rootString(forKey: "workbench.colorTheme"), "Light Modern")
        XCTAssertEqual(try editor.rootBoolean(forKey: "window.autoDetectColorScheme"), false)
    }

    func testMigrationWrapsFlatColorsWithoutLosingTheirTextOrComments() throws {
        let source = """
        {
            "before": 1,
            "workbench.colorCustomizations": {
                // user's dark overrides
                "editor.foreground": "#CCCCCC",
                "terminal.ansiRed": "#F74949",
            },
            "after": 2,
        }
        """
        var editor = try JSONCEditor(source)
        let changed = try editor.installVSCodeThemeColorBlocks(lightColors: [
            ("editor.background", "#FFFFFF"),
            ("terminal.ansiRed", "#CF222E"),
        ])

        XCTAssertTrue(changed)
        XCTAssertTrue(editor.source.contains("// user's dark overrides"))
        XCTAssertTrue(editor.source.contains("\"editor.foreground\": \"#CCCCCC\""))
        XCTAssertTrue(editor.source.contains("\"[Dark Modern]\""))
        XCTAssertTrue(editor.source.contains("\"[Light Modern]\""))
        XCTAssertTrue(editor.source.contains("\"editor.background\": \"#FFFFFF\""))
        XCTAssertEqual(editor.source.components(separatedBy: "\"before\": 1").count, 2)
        XCTAssertEqual(editor.source.components(separatedBy: "\"after\": 2").count, 2)
        _ = try JSONCEditor(data: editor.data)
    }

    func testDoesNotClaimPreexistingThemeBlocksWithoutOwnership() throws {
        var editor = try JSONCEditor("""
        {
          "workbench.colorCustomizations": {
            "[Dark Modern]": {},
            "[Light Modern]": {},
          },
        }
        """)
        XCTAssertThrowsError(try editor.installVSCodeThemeColorBlocks(lightColors: []))
    }

    func testArrayMergeIsIdempotent() throws {
        var editor = try JSONCEditor("""
        {
          "settingsSync.ignoredSettings": [
            "editor.fontSize", // retain
          ],
        }
        """)
        try editor.appendUniqueString("workbench.colorTheme", toRootArray: "settingsSync.ignoredSettings")
        let once = editor.data
        try editor.appendUniqueString("workbench.colorTheme", toRootArray: "settingsSync.ignoredSettings")
        XCTAssertEqual(editor.data, once)
        XCTAssertEqual(
            try editor.rootStringArray(forKey: "settingsSync.ignoredSettings"),
            ["editor.fontSize", "workbench.colorTheme"]
        )
        XCTAssertTrue(editor.source.contains("// retain"))
    }
}
