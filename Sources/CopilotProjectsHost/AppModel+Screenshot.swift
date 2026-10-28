import AppKit
import ScreenCaptureKit
import CopilotProjectsCore
import Darwin

private final class ScreenshotCaptureBox: @unchecked Sendable {
    private let lock = NSLock()
    private var result: Result<CGImage, Error>?

    func store(_ result: Result<CGImage, Error>) {
        lock.lock()
        self.result = result
        lock.unlock()
    }

    func load() -> Result<CGImage, Error>? {
        lock.lock()
        defer { lock.unlock() }
        return result
    }
}

struct ScreenshotCaptureRequest: Equatable, Sendable {
    let windowID: CGWindowID
    let width: Int
    let height: Int
}

enum ScreenshotPreparation: Equatable, Sendable {
    case ready(ScreenshotCaptureRequest)
    case failure(String)
}

enum WindowScreenshot {
    typealias ImageCapturer = @Sendable (ScreenshotCaptureRequest) -> Result<CGImage, Error>

    static func defaultDestinationPath() -> String {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Downloads/copilot-projects.png").path
    }

    static func validateDestination(atPath path: String) -> String? {
        guard !path.isEmpty else {
            return "screenshot path must not be empty"
        }
        var st = stat()
        if lstat(path, &st) == 0, (st.st_mode & S_IFMT) != S_IFREG {
            return "refusing to write screenshot to a non-regular file"
        }
        return nil
    }

    static func captureWindowImage(_ request: ScreenshotCaptureRequest) -> Result<CGImage, Error> {
        let result = ScreenshotCaptureBox()
        let semaphore = DispatchSemaphore(value: 0)
        Task.detached {
            defer { semaphore.signal() }
            do {
                let content = try await SCShareableContent.currentProcess
                guard let shareableWindow = content.windows.first(where: {
                    $0.windowID == request.windowID
                }) else {
                    throw NSError(
                        domain: "CopilotProjectsScreenshot",
                        code: 1,
                        userInfo: [NSLocalizedDescriptionKey: "window is not shareable"]
                    )
                }
                let filter = SCContentFilter(desktopIndependentWindow: shareableWindow)
                let configuration = SCStreamConfiguration()
                configuration.width = request.width
                configuration.height = request.height
                configuration.showsCursor = false
                let image = try await SCScreenshotManager.captureImage(
                    contentFilter: filter,
                    configuration: configuration
                )
                result.store(.success(image))
            } catch {
                result.store(.failure(error))
            }
        }
        guard semaphore.wait(timeout: .now() + 5) == .success,
              let captureResult = result.load() else {
            return .failure(NSError(
                domain: "CopilotProjectsScreenshot",
                code: 2,
                userInfo: [NSLocalizedDescriptionKey: "window capture timed out"]
            ))
        }
        return captureResult
    }

    static func writePNG(_ image: CGImage, to path: String) -> ControlResponse {
        if let validationError = validateDestination(atPath: path) {
            return .failure(validationError)
        }
        let rep = NSBitmapImageRep(cgImage: image)
        guard let data = rep.representation(using: .png, properties: [:]) else {
            return .failure("could not encode PNG")
        }

        let destination = URL(fileURLWithPath: path)
        do {
            try FileManager.default.createDirectory(
                at: destination.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            if let validationError = validateDestination(atPath: path) {
                return .failure(validationError)
            }
            try data.write(to: destination)
            return .success(path)
        } catch {
            return .failure("write failed: \(error.localizedDescription)")
        }
    }

    static func capture(
        _ request: ScreenshotCaptureRequest,
        to path: String,
        captureImage: ImageCapturer = captureWindowImage
    ) -> ControlResponse {
        let image: CGImage
        switch captureImage(request) {
        case .success(let captured):
            image = captured
        case .failure(let error):
            let nsError = error as NSError
            if nsError.domain == "CopilotProjectsScreenshot", nsError.code == 2 {
                return .failure("window capture timed out")
            }
            return .failure("could not capture window: \(error.localizedDescription)")
        }
        return writePNG(image, to: path)
    }
}

extension AppModel {
    /// Collects main-thread window metadata; destination validation, capture, and
    /// file I/O run on the control-server thread so ScreenCaptureKit and disk writes
    /// never block UI interaction.
    func prepareScreenshot() -> ScreenshotPreparation {
        if let screenshotPreparer {
            return screenshotPreparer()
        }
        guard let window = NSApp.windows.first(where: { $0.isVisible && $0.contentView != nil })
                ?? NSApp.mainWindow ?? NSApp.windows.first,
              let view = window.contentView else {
            return .failure("no window to capture")
        }
        let bounds = view.bounds
        guard bounds.width > 1, bounds.height > 1 else {
            return .failure("window has no drawable bounds")
        }
        let scale = window.backingScaleFactor
        return .ready(ScreenshotCaptureRequest(
            windowID: CGWindowID(window.windowNumber),
            width: Int(bounds.width * scale),
            height: Int(bounds.height * scale)
        ))
    }
}
