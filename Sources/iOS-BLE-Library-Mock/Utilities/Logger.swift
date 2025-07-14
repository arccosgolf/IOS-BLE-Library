//
//  File.swift
//
//
//  Created by Nick Kibysh on 20/01/2023.
//

import Foundation
import os

public protocol NordicBluetoothLogger {
    func i(_ msg : String)
    func d(_ msg : String)
    func f(_ msg : String)
    func e(_ msg : String)
}

public final class Logger {
    static let shared = Logger()
    
    private var bluetoothLogger: NordicBluetoothLogger?
    
    private init() {}
    
    func configure(with logger: NordicBluetoothLogger) {
        bluetoothLogger = logger
    }
    
    func i(_ msg: String, category: String) {
        bluetoothLogger?.i("[\(category)] \(msg)")
    }
    
    func d(_ msg: String, category: String) {
        bluetoothLogger?.d("[\(category)] \(msg)")
    }
    
    func e(_ msg: String, category: String) {
        bluetoothLogger?.e("[\(category)] \(msg)")
    }
    
    func f(_ msg: String, category: String) {
        bluetoothLogger?.f("[\(category)] \(msg)")
    }
}
