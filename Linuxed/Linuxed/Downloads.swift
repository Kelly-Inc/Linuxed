// SPDX-License-Identifier: GPL-2.0-or-later

import BackgroundTasks
import SwiftUI

/// Puts guest images into Documents.
enum GuestStore {
    nonisolated struct Failure: LocalizedError {
        let errorDescription: String?
        init(_ message: String) { errorDescription = message }
    }

    /// Puts `source` into Documents and returns its name there. Never overwrites.
    nonisolated static func store(_ source: URL, named name: String, move: Bool) throws -> String {
        // The name comes from a server or another app: keep only its last
        // component so it cannot point outside Documents.
        let name = (name as NSString).lastPathComponent
        guard !name.isEmpty, name != ".", name != "..", !name.hasPrefix(".") else {
            throw Failure("That file has no usable name.")
        }
        let target = URL.documentsDirectory.appending(path: name)
        guard !FileManager.default.fileExists(atPath: target.path) else {
            throw Failure("\(name) is already in Linuxed.")
        }
        try FileManager.default.createDirectory(at: .documentsDirectory, withIntermediateDirectories: true)
        if move {
            try FileManager.default.moveItem(at: source, to: target)
        } else {
            try FileManager.default.copyItem(at: source, to: target)
        }
        return name
    }
}

/// The one guest download at a time. The transfer runs in a background URL
/// session, so it continues while Linuxed is suspended or closed, and an iOS
/// continued processing task shows it as a system Live Activity with progress.
@MainActor
@Observable
final class Downloads: NSObject, URLSessionDownloadDelegate {
    static let shared = Downloads()

    /// The name of the file being downloaded, if any.
    private(set) var active: String?
    private(set) var fraction = 0.0
    var failure: String?
    /// Why iOS showed no Live Activity for the download, if it said.
    private(set) var activityNote: String?
    /// The name of the last guest stored; views watch it to refresh.
    private(set) var finished: String?
    /// What iOS wants called once a relaunch has handled the session's events.
    @ObservationIgnored var backgroundCompletion: (() -> Void)?

    @ObservationIgnored private var session: URLSession?
    @ObservationIgnored private var transfer: URLSessionDownloadTask?
    @ObservationIgnored private var activity: BGContinuedProcessingTask?
    @ObservationIgnored private var registered = false

    private static let bundleID = Bundle.main.bundleIdentifier ?? "lol.respring.linuxed"
    /// Covered by the guest.* entry of BGTaskSchedulerPermittedIdentifiers.
    private static let activityID = "\(bundleID).guest.download"

    /// Connects to the background session, at launch and when iOS relaunches
    /// the app for it, and picks up a download that outlived the last run.
    func resume() {
        guard session == nil else { return }
        let configuration = URLSessionConfiguration.background(withIdentifier: "\(Self.bundleID).downloads")
        configuration.sessionSendsLaunchEvents = true
        configuration.isDiscretionary = false
        let session = URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
        self.session = session
        session.getAllTasks { @Sendable tasks in
            guard let task = tasks.first as? URLSessionDownloadTask else { return }
            let name = task.originalRequest?.url?.lastPathComponent ?? "guest"
            nonisolated(unsafe) let handed = task
            Task { @MainActor in
                guard self.active == nil else { return }
                self.transfer = handed
                self.active = name
            }
        }
    }

    func start(_ url: URL) {
        resume()
        guard active == nil, let session else { return }
        failure = nil
        fraction = 0
        let name = url.lastPathComponent.isEmpty ? (url.host() ?? "guest") : url.lastPathComponent
        active = name
        let task = session.downloadTask(with: url)
        transfer = task
        task.resume()
        showActivity(name: name)
    }

    func cancel() {
        transfer?.cancel()
    }

    // MARK: The system Live Activity

    private func showActivity(name: String) {
        if !registered {
            registered = BGTaskScheduler.shared.register(
                forTaskWithIdentifier: Self.activityID, using: nil
            ) { @Sendable task in
                // @Sendable keeps these system-queue callbacks off the main
                // actor; without it Swift 6 traps when iOS calls them.
                guard let continued = task as? BGContinuedProcessingTask else {
                    return task.setTaskCompleted(success: false)
                }
                // The handler runs on a system queue; the downloads live on the main actor.
                nonisolated(unsafe) let handed = continued
                Task { @MainActor in Downloads.shared.began(handed) }
            }
        }
        activityNote = registered ? nil : "iOS did not accept the Live Activity registration."
        let request = BGContinuedProcessingTaskRequest(
            identifier: Self.activityID,
            title: "Downloading \(name)",
            subtitle: "Starting"
        )
        request.strategy = .fail
        // iOS 27 submits off the calling thread (as BackgroundJob does).
        nonisolated(unsafe) let handed = request
        DispatchQueue.global(qos: .userInitiated).async {
            // A refusal only costs the Live Activity; the download itself continues.
            BGTaskScheduler.shared.submitTaskRequest(handed) { @Sendable error in
                guard let error else { return }
                NSLog("Linuxed: download activity refused: %@", "\(error)")
                let note = "No Live Activity: \(error.localizedDescription) (\((error as NSError).domain) \((error as NSError).code))"
                Task { @MainActor in Downloads.shared.activityNote = note }
            }
        }
    }

    private func began(_ task: BGContinuedProcessingTask) {
        guard active != nil else { return task.setTaskCompleted(success: true) }
        activity = task
        task.progress.totalUnitCount = 100
        task.progress.completedUnitCount = Int64(fraction * 100)
        // shortcut: iOS calls this both when the user taps Stop on the Live
        // Activity and when it ends the task itself, and does not say which;
        // both cancel the download. Keep resume data if that proves too eager.
        task.expirationHandler = { @Sendable in
            Task { @MainActor in Downloads.shared.cancel() }
        }
    }

    private func progressed(_ fraction: Double) {
        let percent = Int64(fraction * 100)
        if let activity, let active, activity.progress.completedUnitCount != percent {
            activity.progress.completedUnitCount = percent
            activity.updateTitle("Downloading \(active)", subtitle: "\(percent)%")
        }
        self.fraction = fraction
    }

    private func ended(stored: String?, failure: String?) {
        activity?.setTaskCompleted(success: stored != nil)
        activity = nil
        BGTaskScheduler.shared.cancel(taskRequestWithIdentifier: Self.activityID)
        transfer = nil
        active = nil
        if let failure { self.failure = failure }
        if let stored { finished = stored }
    }

    // MARK: URLSessionDownloadDelegate

    nonisolated func urlSession(
        _ session: URLSession, downloadTask: URLSessionDownloadTask,
        didWriteData bytesWritten: Int64, totalBytesWritten: Int64,
        totalBytesExpectedToWrite: Int64
    ) {
        guard totalBytesExpectedToWrite > 0 else { return }
        let fraction = Double(totalBytesWritten) / Double(totalBytesExpectedToWrite)
        Task { @MainActor in self.progressed(fraction) }
    }

    nonisolated func urlSession(
        _ session: URLSession, downloadTask: URLSessionDownloadTask,
        didFinishDownloadingTo location: URL
    ) {
        // The file at `location` is gone once this returns, so it is stored here.
        let result: Result<String, Error> = Result {
            if let http = downloadTask.response as? HTTPURLResponse,
               !(200..<300).contains(http.statusCode) {
                throw GuestStore.Failure("The server answered \(http.statusCode).")
            }
            let name = downloadTask.response?.suggestedFilename
                ?? downloadTask.originalRequest?.url?.lastPathComponent ?? ""
            return try GuestStore.store(location, named: name, move: true)
        }
        let stored = try? result.get()
        var failure: String?
        if case let .failure(error) = result { failure = error.localizedDescription }
        Task { @MainActor [failure] in self.ended(stored: stored, failure: failure) }
    }

    nonisolated func urlSession(
        _ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?
    ) {
        // Success was handled when the file arrived.
        guard let error else { return }
        let cancelled = (error as? URLError)?.code == .cancelled
        let message = cancelled ? nil : error.localizedDescription
        Task { @MainActor in self.ended(stored: nil, failure: message) }
    }

    nonisolated func urlSessionDidFinishEvents(forBackgroundURLSession session: URLSession) {
        Task { @MainActor in
            self.backgroundCompletion?()
            self.backgroundCompletion = nil
        }
    }
}

/// Lets iOS relaunch Linuxed to finish a download that completed without it.
extension LinuxedAppDelegate {
    func application(
        _ application: UIApplication,
        handleEventsForBackgroundURLSession identifier: String,
        completionHandler: @escaping () -> Void
    ) {
        Downloads.shared.backgroundCompletion = completionHandler
        Downloads.shared.resume()
    }
}
