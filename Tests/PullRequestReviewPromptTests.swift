import AppKit
import XCTest
import CopilotProjectsCore
import CopilotProjectsProtocol
@testable import CopilotProjectsHost

@MainActor
final class PullRequestReviewPromptTests: XCTestCase {
    private let legacyPrompt = "Perform a read-only local adversarial review of {url}. "
        + "Use the adversarial-review skill. Inspect the pull request from a local checkout "
        + "or isolated worktree. Do not edit files, push changes, or post anything to GitHub. "
        + "Report the findings in this session."

    override func setUp() {
        super.setUp()
        _ = NSApplication.shared
    }

    func testBuiltInMatchesTheLegacyReviewPrompt() throws {
        let url = "https://github.com/github/github/pull/123"
        let target = try XCTUnwrap(PullRequestReviewTarget.parse(url))
        XCTAssertEqual(PullRequestReviewPrompt.builtIn.template, legacyPrompt)
        XCTAssertEqual(
            PullRequestReviewPrompt.validated(PullRequestReviewPrompt.builtIn.template),
            .success(.builtIn)
        )
        XCTAssertEqual(
            PullRequestReviewPrompt.builtIn.prompt(for: target),
            legacyPrompt.replacingOccurrences(of: "{url}", with: url)
        )
        XCTAssertTrue(PullRequestReviewPrompt.builtIn.isBuiltIn)
        XCTAssertEqual(SessionInputValidation.maximumPromptBytes, 8_192)
        XCTAssertEqual(SessionInputValidation.maximumPromptBytes, CLIMain.maximumPromptBytes)
    }

    func testValidatedNormalizesAndSubstitutesEveryPlaceholder() throws {
        let target = try sampleTarget()
        let prompt = try XCTUnwrap(PullRequestReviewPrompt.validated(
            "\r\n  Review {url} twice: {url}\r\n"
        ).get())
        XCTAssertEqual(prompt.template, "Review {url} twice: {url}")
        XCTAssertEqual(
            prompt.prompt(for: target),
            "Review \(target.url) twice: \(target.url)"
        )
        XCTAssertFalse(prompt.isBuiltIn)

        let spaced = try XCTUnwrap(PullRequestReviewPrompt.validated("Review\n\t{url}\n").get())
        XCTAssertEqual(spaced.prompt(for: target), "Review\n\t\(target.url)")
    }

    func testValidatedRejectsEmptyMissingPlaceholderAndControls() {
        XCTAssertEqual(PullRequestReviewPrompt.validated(""), .failure(.empty))
        XCTAssertEqual(PullRequestReviewPrompt.validated(" \n\t\r\n"), .failure(.empty))
        XCTAssertEqual(
            PullRequestReviewPrompt.validated("Review this pull request."),
            .failure(.missingURLPlaceholder)
        )
        XCTAssertEqual(PullRequestReviewPrompt.validated("{URL}"), .failure(.missingURLPlaceholder))

        for raw in ["Review \u{07} {url}", "Review \u{0} {url}", "Review \u{1b} {url}", "Review \u{7f} {url}", "Review \u{9b} {url}"] {
            XCTAssertEqual(
                PullRequestReviewPrompt.validated(raw),
                .failure(.unsupportedCharacters),
                raw
            )
        }
        let hugeWithControl = "Review \u{07} {url}" + String(repeating: "x", count: 9_000)
        XCTAssertEqual(
            PullRequestReviewPrompt.validated(hugeWithControl),
            .failure(.unsupportedCharacters)
        )
        XCTAssertEqual(PullRequestReviewPrompt.ValidationError.empty.message, "Enter a review prompt.")
        XCTAssertEqual(
            PullRequestReviewPrompt.ValidationError.missingURLPlaceholder.message,
            "Include {url} where the pull request URL should be inserted."
        )
        XCTAssertEqual(
            PullRequestReviewPrompt.ValidationError.unsupportedCharacters.message,
            "Remove terminal control characters from the prompt."
        )
    }

    func testValidatedReservesTheLongestURLForEveryPlaceholder() throws {
        try assertBudget(placeholders: 1)
        try assertBudget(placeholders: 3)
        let reported = reportedBudget(placeholders: 3)
        XCTAssertLessThan(reported, reportedBudget(placeholders: 1))
        XCTAssertEqual(
            PullRequestReviewPrompt.ValidationError.tooLong(maximumBytes: reported).message,
            "Keep the prompt to at most \(reported.formatted(.number.locale(Locale(identifier: "en_US")))) UTF-8 bytes so the pull request URL fits."
        )
    }

    func testStoredPromptRoundTripsAndIgnoresInvalidValues() throws {
        let suite = "PullRequestReviewPromptTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }

        XCTAssertEqual(PullRequestReviewPrompt.stored(in: defaults), .builtIn)
        XCTAssertNil(defaults.string(forKey: PullRequestReviewPrompt.defaultsKey))

        let custom = try XCTUnwrap(PullRequestReviewPrompt.validated("Review {url} for security only.").get())
        custom.save(to: defaults)
        XCTAssertEqual(defaults.string(forKey: PullRequestReviewPrompt.defaultsKey), custom.template)
        XCTAssertEqual(PullRequestReviewPrompt.stored(in: defaults), custom)

        PullRequestReviewPrompt.builtIn.save(to: defaults)
        XCTAssertNil(defaults.object(forKey: PullRequestReviewPrompt.defaultsKey))
        XCTAssertEqual(PullRequestReviewPrompt.stored(in: defaults), .builtIn)

        custom.save(to: defaults)
        PullRequestReviewPrompt.reset(in: defaults)
        XCTAssertNil(defaults.object(forKey: PullRequestReviewPrompt.defaultsKey))
        PullRequestReviewPrompt.reset(in: defaults)
        XCTAssertEqual(PullRequestReviewPrompt.stored(in: defaults), .builtIn)

        defaults.set("   \n", forKey: PullRequestReviewPrompt.defaultsKey)
        XCTAssertEqual(PullRequestReviewPrompt.stored(in: defaults), .builtIn)
        XCTAssertEqual(defaults.string(forKey: PullRequestReviewPrompt.defaultsKey), "   \n")

        defaults.set("Review this pull request.", forKey: PullRequestReviewPrompt.defaultsKey)
        XCTAssertEqual(PullRequestReviewPrompt.stored(in: defaults), .builtIn)
        XCTAssertEqual(defaults.string(forKey: PullRequestReviewPrompt.defaultsKey), "Review this pull request.")

        defaults.set("Review \u{07} {url}", forKey: PullRequestReviewPrompt.defaultsKey)
        XCTAssertEqual(PullRequestReviewPrompt.stored(in: defaults), .builtIn)
        XCTAssertEqual(defaults.string(forKey: PullRequestReviewPrompt.defaultsKey), "Review \u{07} {url}")
        XCTAssertFalse(PullRequestReviewPrompt.defaultsKey.contains("."))
    }

    func testEditorSaveRestoreAndCancel() throws {
        let custom = try XCTUnwrap(PullRequestReviewPrompt.validated("Review {url}.").get())
        var restorePresentations = 0
        let restored = PullRequestReviewPromptEditor.runModal(initialPrompt: custom) { alert in
            restorePresentations += 1
            XCTAssertEqual(alert.messageText, "Pull Request Review Prompt")
            XCTAssertEqual(alert.buttons.map(\.title), ["Save", "Cancel", "Restore Default"])
            XCTAssertEqual(alert.buttons[0].keyEquivalent, "\r")
            XCTAssertEqual(alert.buttons[0].keyEquivalentModifierMask, [.command])
            XCTAssertEqual(alert.buttons[1].keyEquivalent, "\u{1b}")
            let editor = textView(in: alert)
            if restorePresentations == 1 {
                XCTAssertEqual(editor.string, custom.template)
                XCTAssertEqual(editor.selectedRange().length, (custom.template as NSString).length)
                return NSApplication.ModalResponse(
                    rawValue: NSApplication.ModalResponse.alertFirstButtonReturn.rawValue + 2
                )
            }
            XCTAssertEqual(editor.string, PullRequestReviewPrompt.builtIn.template)
            XCTAssertFalse(alert.informativeText.contains("Enter a review prompt."))
            return .alertFirstButtonReturn
        }
        XCTAssertEqual(restorePresentations, 2)
        XCTAssertEqual(restored, .builtIn)

        var invalidPresentations = 0
        let cancelled = PullRequestReviewPromptEditor.runModal(initialPrompt: .builtIn) { alert in
            invalidPresentations += 1
            let editor = textView(in: alert)
            if invalidPresentations == 1 {
                editor.string = "Review \u{07} {url}"
                return .alertFirstButtonReturn
            }
            XCTAssertEqual(editor.string, "Review \u{07} {url}")
            XCTAssertTrue(alert.informativeText.contains(
                PullRequestReviewPrompt.ValidationError.unsupportedCharacters.message
            ))
            return .alertSecondButtonReturn
        }
        XCTAssertNil(cancelled)
        XCTAssertEqual(invalidPresentations, 2)

        let saved = PullRequestReviewPromptEditor.runModal(initialPrompt: .builtIn) { alert in
            textView(in: alert).string = "  Review {url}.\r\n"
            return .alertFirstButtonReturn
        }
        XCTAssertEqual(saved?.template, "Review {url}.")

        let abandoned = PullRequestReviewPromptEditor.runModal(initialPrompt: custom) { _ in
            .alertSecondButtonReturn
        }
        XCTAssertNil(abandoned)
    }

    func testConfigureSavesAndCancelLeavesStoredPrompt() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let suite = "PullRequestReviewPromptTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let model = AppModel(
            stateRepository: StateRepository(path: root.appendingPathComponent("state.json")),
            isAppActive: { false },
            agentActivityDirectory: root,
            resumeMarkerDirectory: root,
            kittyImageDiskStore: RemoteKittyImageDiskStore(
                root: root.appendingPathComponent("images", isDirectory: true)
            ),
            defaults: defaults
        )

        var cancelled = 0
        model.configurePullRequestReviewPromptInteractive { _ in
            cancelled += 1
            return .alertSecondButtonReturn
        }
        XCTAssertEqual(cancelled, 1)
        XCTAssertEqual(PullRequestReviewPrompt.stored(in: defaults), .builtIn)
        XCTAssertNil(defaults.string(forKey: PullRequestReviewPrompt.defaultsKey))

        model.configurePullRequestReviewPromptInteractive { alert in
            textView(in: alert).string = "Review {url} for security only."
            return .alertFirstButtonReturn
        }
        let target = try sampleTarget()
        XCTAssertEqual(
            model.pullRequestReviewPrompt(for: target),
            "Review \(target.url) for security only."
        )
    }

    private func sampleTarget() throws -> PullRequestReviewTarget {
        try XCTUnwrap(PullRequestReviewTarget.parse("https://github.com/o/r/pull/7"))
    }

    private func reportedBudget(placeholders: Int) -> Int {
        let expansion = PullRequestReviewTarget.maximumInputBytes
            - PullRequestReviewPrompt.urlPlaceholder.utf8.count
        return SessionInputValidation.maximumPromptBytes - placeholders * expansion
    }

    private func template(placeholders: Int, utf8Bytes: Int) -> String {
        let marker = Array(repeating: PullRequestReviewPrompt.urlPlaceholder, count: placeholders)
            .joined(separator: " ")
        return marker + String(repeating: "x", count: utf8Bytes - marker.utf8.count)
    }

    private func assertBudget(placeholders: Int) throws {
        let budget = reportedBudget(placeholders: placeholders)
        let exact = template(placeholders: placeholders, utf8Bytes: budget)
        let prompt = try XCTUnwrap(PullRequestReviewPrompt.validated(exact).get())
        let worstURL = String(repeating: "a", count: PullRequestReviewTarget.maximumInputBytes)
        let worst = prompt.template.replacingOccurrences(
            of: PullRequestReviewPrompt.urlPlaceholder,
            with: worstURL
        )
        XCTAssertEqual(worst.utf8.count, SessionInputValidation.maximumPromptBytes)
        XCTAssertTrue(SessionInputValidation.isValidPrompt(worst))
        XCTAssertTrue(SessionInputValidation.isValidPrompt(prompt.prompt(for: try sampleTarget())))

        let over = template(placeholders: placeholders, utf8Bytes: budget + 1)
        XCTAssertEqual(
            PullRequestReviewPrompt.validated(over),
            .failure(.tooLong(maximumBytes: budget))
        )
    }

    private func textView(in alert: NSAlert) -> NSTextView {
        guard let textView = (alert.accessoryView as? NSScrollView)?.documentView as? NSTextView else {
            XCTFail("review prompt editor is missing")
            return NSTextView()
        }
        return textView
    }
}
