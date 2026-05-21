//
//  AtlasLogger.swift
//  Atlas
//
//  Centralized logging for the Atlas extraction pipeline and AI backends.
//  All logs go to os_log (visible in Console.app and Xcode console).
//

import Foundation
import os.log

enum AtlasLogger {
    private static let subsystem = "com.atlas.pdf"

    static let pipeline = Logger(subsystem: subsystem, category: "pipeline")
    static let ai       = Logger(subsystem: subsystem, category: "ai")
    static let graph    = Logger(subsystem: subsystem, category: "graph")
    static let text     = Logger(subsystem: subsystem, category: "text")
    static let sync     = Logger(subsystem: subsystem, category: "sync")
    static let ui       = Logger(subsystem: subsystem, category: "ui")
    static let headless = Logger(subsystem: subsystem, category: "headless")
    static let embedding = Logger(subsystem: subsystem, category: "embedding")
}
