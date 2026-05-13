import Foundation
import CryptoKit

// MARK: - Model manifest

/// Describes a single model asset that must exist locally for the app to function.
public struct ModelAsset {
    public let id: String            // internal identifier
    public let filename: String      // local filename after download (e.g. "ggml-large-v3-turbo-q5_0.bin")
    public let downloadFilename: String  // filename on GitHub (same, or .zip for directories)
    public let expectedSize: Int64   // bytes (of the download file)
    public let sha256: String        // hex digest of the download file
    public let isZipped: Bool        // if true, unzip after download
    public let displayName: String   // shown in UI (localization key)
    public let displaySize: String   // e.g. "547 MB"
}

/// Progress snapshot for UI updates.
public struct DownloadProgress {
    public let currentAsset: ModelAsset
    public let currentIndex: Int     // 0-based
    public let totalAssets: Int
    public let fileBytesWritten: Int64
    public let fileTotalBytes: Int64
    public let overallBytesWritten: Int64
    public let overallTotalBytes: Int64
}

// MARK: - ModelManager

/// Manages detection and downloading of ML models that the app requires.
/// Models are stored in ~/Library/Application Support/VoiceInk/models/
/// and downloaded from GitHub Releases on first launch.
public final class ModelManager: NSObject, URLSessionDownloadDelegate {

    /// Where models live on disk.
    public static let modelsDir: URL = {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return appSupport.appendingPathComponent("VoiceInk/models", isDirectory: true)
    }()

    /// GitHub Release tag that holds the model assets.
    private static let modelsTag = "models-v1"
    private static let repoSlug = "gendalf-warden/voiceink"

    /// The authoritative list of models the app needs.
    /// SHA256 values are filled in by scripts/upload-models.sh after uploading.
    public static let assets: [ModelAsset] = [
        ModelAsset(
            id: "whisper-bin",
            filename: "ggml-large-v3-turbo-q5_0.bin",
            downloadFilename: "ggml-large-v3-turbo-q5_0.bin",
            expectedSize: 574_041_195,
            sha256: "394221709cd5ad1f40c46e6031ca61bce88931e6e088c188294c6d5a55ffa7e2",
            isZipped: false,
            displayName: "download.whisper_model",
            displaySize: "547 MB"
        ),
        ModelAsset(
            id: "whisper-coreml",
            filename: "ggml-large-v3-turbo-encoder.mlmodelc",
            downloadFilename: "ggml-large-v3-turbo-encoder.mlmodelc.zip",
            expectedSize: 1_172_990_001,
            sha256: "60d2d856fd2e8f3d94c1fc08e7b12cb35826b0bd027c9a9d3bef011f11f585d6",
            isZipped: true,
            displayName: "download.coreml_model",
            displaySize: "1.1 GB"
        ),
        ModelAsset(
            id: "qwen-gguf",
            filename: "qwen2.5-3b.gguf",
            downloadFilename: "qwen2.5-3b.gguf",
            expectedSize: 1_929_903_008,
            sha256: "5ee4f07cdb9beadbbb293e85803c569b01bd37ed059d2715faa7bb405f31caa6",
            isZipped: false,
            displayName: "download.llm_model",
            displaySize: "1.8 GB"
        ),
    ]

    /// Total download size across all assets.
    public static var totalDownloadSize: Int64 {
        assets.reduce(0) { $0 + $1.expectedSize }
    }

    // MARK: - Detection

    /// Returns the subset of `assets` that are not yet present on disk.
    public static func missingModels() -> [ModelAsset] {
        let fm = FileManager.default
        return assets.filter { asset in
            let path = modelsDir.appendingPathComponent(asset.filename).path
            if asset.isZipped {
                // For directories (mlmodelc), check the directory exists
                var isDir: ObjCBool = false
                return !(fm.fileExists(atPath: path, isDirectory: &isDir) && isDir.boolValue)
            } else {
                return !fm.fileExists(atPath: path)
            }
        }
    }

    /// Check available disk space. Returns true if enough free space.
    public static func checkDiskSpace(needed: Int64) -> Bool {
        do {
            // Ensure parent directory exists before querying volume capacity.
            // On first launch the Application Support/VoiceInk dir may not exist yet.
            let parentDir = modelsDir.deletingLastPathComponent()
            try FileManager.default.createDirectory(at: parentDir, withIntermediateDirectories: true)
            let values = try parentDir
                .resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
            let available = values.volumeAvailableCapacityForImportantUsage ?? 0
            return available > needed
        } catch {
            log("Cannot check disk space: \(error)", tag: "ModelManager")
            return true // optimistic
        }
    }

    // MARK: - Download

    private var session: URLSession!
    private var currentTask: URLSessionDownloadTask?
    private var models: [ModelAsset] = []
    private var currentIndex = 0
    private var completedBytes: Int64 = 0  // bytes from already-finished files
    private var onProgress: ((DownloadProgress) -> Void)?
    private var onComplete: ((Result<Void, Error>) -> Void)?
    private var isCancelled = false

    /// Download the given models sequentially. Calls `progress` on main thread,
    /// calls `completion` on main thread when all done (or on error/cancel).
    public func download(
        models: [ModelAsset],
        progress: @escaping (DownloadProgress) -> Void,
        completion: @escaping (Result<Void, Error>) -> Void
    ) {
        self.models = models
        self.currentIndex = 0
        self.completedBytes = 0
        self.onProgress = progress
        self.onComplete = completion
        self.isCancelled = false

        // Create models directory
        try? FileManager.default.createDirectory(
            at: ModelManager.modelsDir,
            withIntermediateDirectories: true
        )

        // URLSession with delegate for progress tracking
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForResource = 3600  // 1 hour max per file
        session = URLSession(configuration: config, delegate: self, delegateQueue: nil)

        downloadNext()
    }

    /// Cancel the current download. Saves resume data for next launch.
    public func cancel() {
        isCancelled = true
        currentTask?.cancel(byProducingResumeData: { [weak self] data in
            guard let self = self, let data = data else { return }
            let asset = self.models[self.currentIndex]
            let resumePath = ModelManager.modelsDir
                .appendingPathComponent(asset.downloadFilename + ".resumedata")
            try? data.write(to: resumePath)
            log("Saved resume data for \(asset.downloadFilename)", tag: "ModelManager")
        })
        DispatchQueue.main.async {
            self.onComplete?(.failure(ModelDownloadError.cancelled))
        }
    }

    // MARK: - Private download logic

    private func downloadNext() {
        guard currentIndex < models.count else {
            log("All models downloaded successfully", tag: "ModelManager")
            DispatchQueue.main.async { self.onComplete?(.success(())) }
            return
        }
        guard !isCancelled else { return }

        let asset = models[currentIndex]
        let url = downloadURL(for: asset)
        log("Downloading \(asset.downloadFilename) from \(url)", tag: "ModelManager")

        // Check for resume data
        let resumePath = ModelManager.modelsDir
            .appendingPathComponent(asset.downloadFilename + ".resumedata")
        if let resumeData = try? Data(contentsOf: resumePath) {
            log("Resuming download for \(asset.downloadFilename)", tag: "ModelManager")
            try? FileManager.default.removeItem(at: resumePath)
            currentTask = session.downloadTask(withResumeData: resumeData)
        } else {
            currentTask = session.downloadTask(with: url)
        }
        currentTask?.resume()
    }

    private func downloadURL(for asset: ModelAsset) -> URL {
        URL(string: "https://github.com/\(ModelManager.repoSlug)/releases/download/\(ModelManager.modelsTag)/\(asset.downloadFilename)")!
    }

    // MARK: - URLSessionDownloadDelegate

    public func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didWriteData bytesWritten: Int64,
        totalBytesWritten: Int64,
        totalBytesExpectedToWrite: Int64
    ) {
        guard currentIndex < models.count else { return }
        let asset = models[currentIndex]
        let totalExpected = totalBytesExpectedToWrite > 0
            ? totalBytesExpectedToWrite
            : asset.expectedSize

        let progress = DownloadProgress(
            currentAsset: asset,
            currentIndex: currentIndex,
            totalAssets: models.count,
            fileBytesWritten: totalBytesWritten,
            fileTotalBytes: totalExpected,
            overallBytesWritten: completedBytes + totalBytesWritten,
            overallTotalBytes: models.reduce(0) { $0 + $1.expectedSize }
        )
        DispatchQueue.main.async { self.onProgress?(progress) }
    }

    public func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didFinishDownloadingTo location: URL
    ) {
        guard currentIndex < models.count else { return }
        let asset = models[currentIndex]

        do {
            // Verify SHA256 if we have a hash
            if !asset.sha256.isEmpty {
                let fileData = try Data(contentsOf: location)
                let digest = SHA256.hash(data: fileData)
                let hex = digest.map { String(format: "%02x", $0) }.joined()
                guard hex == asset.sha256 else {
                    throw ModelDownloadError.hashMismatch(
                        expected: asset.sha256, got: hex, file: asset.downloadFilename
                    )
                }
                log("SHA256 verified for \(asset.downloadFilename)", tag: "ModelManager")
            }

            let destDir = ModelManager.modelsDir

            if asset.isZipped {
                // Unzip to models directory
                let zipDest = destDir.appendingPathComponent(asset.downloadFilename)
                try? FileManager.default.removeItem(at: zipDest)
                try FileManager.default.moveItem(at: location, to: zipDest)

                let process = Process()
                process.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
                process.arguments = ["-o", zipDest.path, "-d", destDir.path]
                process.standardOutput = nil
                process.standardError = nil
                try process.run()
                process.waitUntilExit()

                guard process.terminationStatus == 0 else {
                    throw ModelDownloadError.unzipFailed(asset.downloadFilename)
                }

                // Clean up zip
                try? FileManager.default.removeItem(at: zipDest)
                log("Unzipped \(asset.filename)", tag: "ModelManager")
            } else {
                // Move directly to models dir
                let dest = destDir.appendingPathComponent(asset.filename)
                try? FileManager.default.removeItem(at: dest)
                try FileManager.default.moveItem(at: location, to: dest)
            }

            // Clean up any resume data
            let resumePath = destDir.appendingPathComponent(asset.downloadFilename + ".resumedata")
            try? FileManager.default.removeItem(at: resumePath)

            completedBytes += asset.expectedSize
            currentIndex += 1
            log("Completed \(asset.filename) (\(currentIndex)/\(models.count))", tag: "ModelManager")
            downloadNext()
        } catch {
            log("Download post-processing failed for \(asset.downloadFilename): \(error)", tag: "ModelManager")
            DispatchQueue.main.async {
                self.onComplete?(.failure(error))
            }
        }
    }

    public func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didCompleteWithError error: Error?
    ) {
        guard let error = error else { return } // success handled in didFinishDownloadingTo
        guard !isCancelled else { return } // cancel handled separately

        let nsError = error as NSError
        // Save resume data if available
        if let resumeData = nsError.userInfo[NSURLSessionDownloadTaskResumeData] as? Data,
           currentIndex < models.count {
            let asset = models[currentIndex]
            let resumePath = ModelManager.modelsDir
                .appendingPathComponent(asset.downloadFilename + ".resumedata")
            try? resumeData.write(to: resumePath)
            log("Saved resume data after error for \(asset.downloadFilename)", tag: "ModelManager")
        }

        log("Download error: \(error)", tag: "ModelManager")
        DispatchQueue.main.async {
            self.onComplete?(.failure(error))
        }
    }
}

// MARK: - Errors

public enum ModelDownloadError: LocalizedError {
    case cancelled
    case hashMismatch(expected: String, got: String, file: String)
    case unzipFailed(String)
    case insufficientDiskSpace(needed: Int64, available: Int64)

    public var errorDescription: String? {
        switch self {
        case .cancelled:
            return "Download cancelled"
        case .hashMismatch(let expected, let got, let file):
            return "SHA256 mismatch for \(file): expected \(expected.prefix(12))..., got \(got.prefix(12))..."
        case .unzipFailed(let file):
            return "Failed to unzip \(file)"
        case .insufficientDiskSpace(let needed, let available):
            let neededGB = String(format: "%.1f", Double(needed) / 1_073_741_824)
            let availGB = String(format: "%.1f", Double(available) / 1_073_741_824)
            return "Not enough disk space: need \(neededGB) GB, have \(availGB) GB"
        }
    }
}
