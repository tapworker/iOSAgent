import Foundation
import Gzip
import UIKit

/// Reporter to queue and submit the Beacons
public class Reporter {
    typealias Submitter = (Beacon) -> Void
    typealias Completion = (BeaconResult) -> Void
    typealias NetworkLoader = (URLRequest, @escaping (InstanaNetworking.Result) -> Void) -> Void
    var completionHandler = [Completion]()
    let queue: InstanaPersistableQueue<CoreBeacon>
    private let backgroundQueue = DispatchQueue(label: "com.instana.ios.agent.background", qos: .background)
    private let send: NetworkLoader
    private let batterySafeForNetworking: () -> Bool
    private let networkUtility: NetworkUtility
    private var suspendReporting: Set<InstanaConfiguration.SuspendReporting> { session.configuration.suspendReporting }
    private let session: InstanaSession
    private var flushWorkItem: DispatchWorkItem?
    private var flushSemaphore: DispatchSemaphore?
    private var backgroundTaskID: UIBackgroundTaskIdentifier?

    // MARK: Init

    init(_ session: InstanaSession,
         batterySafeForNetworking: @escaping () -> Bool = { InstanaSystemUtils.battery.safeForNetworking },
         networkUtility: NetworkUtility = NetworkUtility(),
         send: @escaping NetworkLoader = InstanaNetworking().send(request:completion:)) {
        self.networkUtility = networkUtility
        self.session = session
        self.batterySafeForNetworking = batterySafeForNetworking
        self.send = send
        queue = InstanaPersistableQueue<CoreBeacon>(maxItems: session.configuration.maxBeaconsPerRequest)
        networkUtility.connectionUpdateHandler = { [weak self] connectionType in
            guard let self = self else { return }
            if connectionType != .none {
                self.scheduleFlush()
            }
        }
        InstanaApplicationStateHandler.shared.listen { [weak self] state in
            guard let self = self else { return }
            if state == .background {
                self.runBackgroundFlush()
            }
        }
    }

    func submit(_ beacon: Beacon, _ completion: (() -> Void)? = nil) {
        backgroundQueue.async(qos: .background) {
            guard !self.queue.isFull else {
                self.session.logger.add("Queue is full - Beacon will be discarded", level: .warning)
                return
            }
            let start = Date()
            guard let coreBeacon = try? CoreBeaconFactory(self.session).map(beacon) else { return }
            self.queue.add(coreBeacon)
            let passed = Date().timeIntervalSince(start)
            self.session.logger.add("\(Date().millisecondsSince1970) Creating the CoreBeacon took \(passed * 1000) ms")
            self.scheduleFlush()
            completion?()
        }
    }

    func scheduleFlush() {
        guard !queue.items.isEmpty else { return }
        flushWorkItem?.cancel()
        let workItem = DispatchWorkItem { [weak self] in
            guard let self = self else { return }
            guard let flushWorkItem = self.flushWorkItem, !flushWorkItem.isCancelled else { return }
            let start = Date()
            self.flushSemaphore = DispatchSemaphore(value: 0)
            self.flushQueue()
            let passed = Date().timeIntervalSince(start)
            self.session.logger.add("Flushing and writing the queue took \(passed * 1000) ms")
            _ = self.flushSemaphore?.wait(timeout: .now() + 20)
            self.flushSemaphore = nil
        }
        flushWorkItem = workItem
        var interval = batterySafeForNetworking() ? session.configuration.transmissionDelay : session.configuration.transmissionLowBatteryDelay
        interval = queue.isFull ? 0.0 : interval
        backgroundQueue.asyncAfter(deadline: .now() + interval, execute: workItem)
    }

    func flushQueue() {
        let connectionType = networkUtility.connectionType
        guard connectionType != .none else {
            complete([], .failure(InstanaError(code: .offline, description: "No connection available")))
            return
        }
        if suspendReporting.contains(.cellularConnection), connectionType == .cellular {
            complete([], .failure(InstanaError(code: .noWifiAvailable, description: "No WIFI Available")))
            return
        }
        if suspendReporting.contains(.lowBattery), !batterySafeForNetworking() {
            complete([], .failure(InstanaError(code: .lowBattery, description: "Battery too low for flushing")))
            return
        }

        let beacons = queue.items
        let beaconsAsString = beacons.asString
        let request: URLRequest
        do {
            request = try createBatchRequest(from: beaconsAsString)
        } catch {
            complete([], .failure(error))
            return
        }
        send(request) { [weak self] result in
            guard let self = self else { return }
            self.session.logger.add("Did transfer beacon\n \(beaconsAsString)")
            switch result {
            case let .failure(error):
                self.complete(beacons, .failure(error))
            case .success(200 ... 299):
                self.complete(beacons, .success)
            case let .success(statusCode):
                self.complete(beacons, .failure(InstanaError(code: .invalidResponse, description: "Invalid repsonse status code: \(statusCode)")))
            }
        }
    }

    func runBackgroundFlush() {
        guard !queue.items.isEmpty else { return }

        backgroundTaskID = UIApplication.shared.beginBackgroundTask(withName: "Finish Instana Reporting Tasks") {
            // End the task if time expires.
            guard let task = self.backgroundTaskID else { return }
            UIApplication.shared.endBackgroundTask(task)
            self.backgroundTaskID = UIBackgroundTaskIdentifier.invalid
        }

        flushQueue()

        DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
            guard let task = self.backgroundTaskID else { return }
            UIApplication.shared.endBackgroundTask(task)
            self.backgroundTaskID = UIBackgroundTaskIdentifier.invalid
        }
    }

    func complete(_ beacons: [CoreBeacon], _ result: BeaconResult) {
        let beaconsToBeRemoved: [CoreBeacon]
        switch result {
        case .success:
            session.logger.add("Did successfully send beacons")
            beaconsToBeRemoved = beacons
        case let .failure(error):
            session.logger.add("Failed to send Beacon batch: \(error)", level: .warning)
            // Beacons will be removed here if queue is full, otherwise the beacons will be kept for the next flush
            beaconsToBeRemoved = queue.isFull ? beacons : []
        }
        queue.remove(beaconsToBeRemoved) { [weak self] _ in
            guard let self = self else { return }
            self.completionHandler.forEach { $0(result) }
            self.flushSemaphore?.signal()
        }
    }
}

extension Reporter {
    func createBatchRequest(from beacons: String) throws -> URLRequest {
        guard !session.configuration.key.isEmpty else {
            throw InstanaError(code: .notAuthenticated, description: "Missing application key. No data will be sent.")
        }

        var urlRequest = URLRequest(url: session.configuration.reportingURL)
        urlRequest.httpMethod = "POST"
        urlRequest.addValue("text/plain", forHTTPHeaderField: "Content-Type")

        let data = beacons.data(using: .utf8)

        if session.configuration.gzipReport, let gzippedData = try? data?.gzipped(level: .bestCompression) {
            urlRequest.httpBody = gzippedData
            urlRequest.setValue("gzip", forHTTPHeaderField: "Content-Encoding")
            urlRequest.setValue("\(gzippedData.count)", forHTTPHeaderField: "Content-Length")
        } else {
            urlRequest.httpBody = data
            urlRequest.setValue("\(data?.count ?? 0)", forHTTPHeaderField: "Content-Length")
        }

        return urlRequest
    }
}
