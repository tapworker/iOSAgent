//
//  File.swift
//  
//
//  Created by Christian Menschel on 05.12.19.
//

import Foundation
@testable import InstanaSensor

class MockReporter: Reporter {
    var submitter: ((Beacon) -> Void)
    init(submitter: @escaping ((Beacon) -> Void)) {
        self.submitter = submitter
        super.init(InstanaConfiguration.default(key: "KEY"))
    }

    init() {
        self.submitter = {_ in}
        super.init(InstanaConfiguration.default(key: "KEY"))
    }

    override func submit(_ b: Beacon) {
        submitter(b)
    }
}