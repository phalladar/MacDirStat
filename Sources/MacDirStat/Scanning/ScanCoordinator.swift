import Foundation

@MainActor
final class ScanCoordinator {
    private let appState: AppState
    private var scanTask: Task<Void, Never>?

    init(appState: AppState) {
        self.appState = appState
    }

    func startScan(path: String) {
        cancel()
        appState.reset()
        appState.scanStatus = .scanning(fileCount: 0, byteCount: 0, currentPath: path)

        let scanner = FileScanner(rootPath: path)
        scanTask = Task {
            var lastUpdate = ContinuousClock.now
            let throttleInterval = Duration.milliseconds(50) // 20 updates/sec

            for await event in scanner.scan() {
                if Task.isCancelled { break }

                switch event {
                case let .progress(fileCount, byteCount, currentPath):
                    let now = ContinuousClock.now
                    if now - lastUpdate >= throttleInterval {
                        appState.scanStatus = .scanning(
                            fileCount: fileCount,
                            byteCount: byteCount,
                            currentPath: currentPath
                        )
                        lastUpdate = now
                    }

                case let .completed(root):
                    appState.setScanCompleted(root: root)

                case let .error(message):
                    appState.scanStatus = .error(message)
                }
            }
        }
    }

    func cancel() {
        scanTask?.cancel()
        scanTask = nil
    }
}
