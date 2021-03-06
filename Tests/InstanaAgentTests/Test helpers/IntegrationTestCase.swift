import Foundation
import XCTest
@testable import InstanaAgent

enum IntegrationTestCaseError: Error {
    case empty
    case unknonw
}

@available(iOS 12.0, *)
class IntegrationTestCase: InstanaTestCase {
    struct Defaults {
        static let serverPort: Int = 9999
        static let baseURL = URL(string: "http://localhost:\(serverPort)")!
        static let someURL = URL(string: "http://localhost:\(serverPort)/some")!
    }

    var expectation: XCTestExpectation!
    var session: URLSession!
    var task: URLSessionTask!
    var mockserver: EchoWebServer!

    override func setUp() {
        super.setUp()

        mockserver = EchoWebServer(port: Defaults.serverPort)
        try! mockserver.start()
        let config = URLSessionConfiguration.default
        session = URLSession(configuration: config)
    }

    override func tearDown() {
        try! mockserver.stop()
        mockserver = nil
        super.tearDown()
    }

    func load(url: URL = Defaults.baseURL, completion: @escaping (Result<Data, Error>) -> Void) {
        expectation = expectation(description: UUID().uuidString)
        var request = URLRequest(url: url)
        request.httpBody = "Key:Value".data(using: .utf8)
        request.addValue("text/plain", forHTTPHeaderField: "Content-Type")
        request.setValue("\(request.httpBody?.count ?? 0)", forHTTPHeaderField: "Content-Length")
        request.httpMethod = "POST"
        request.timeoutInterval = 60.0
        task = session.dataTask(with: request) { (data, response, error) in
            if let error = error {
                completion(Result.failure(error))
            } else if let data = data {
                completion(Result.success(data))
            } else {
                completion(Result.failure(IntegrationTestCaseError.empty))
            }
            self.fulfilled()
        }
        task.resume()

        wait(for: [expectation], timeout: 10.0)
    }

    var serverReceivedBody: [Data] {
        EchoWebServer.requestStorage.receivedRequests.compactMap {$0.body}
    }

    func fulfilled() {
        expectation.fulfill()
    }
}
