//
//  PeripheralError.swift
//  iOS-BLE-Library
//
//  Created by Dinesh Harjani on 26/9/25.
//  Copyright © 2025 Nordic Semiconductor ASA. All rights reserved.
//

import Foundation

// MARK: - PeripheralError

public enum PeripheralError: LocalizedError {
    
    case onlyConnectedPeripheralsHaveNegotiatedMTU
    /// Arccos: a pending discovery operation was abandoned through
    /// ``Peripheral/cleanupQueueOnError()`` before CoreBluetooth answered it.
    case operationCancelled
    
    // MARK: Description
    
    public var errorDescription: String? {
        switch self {
        case .onlyConnectedPeripheralsHaveNegotiatedMTU:
            return "A connected Peripheral is required to obtain a valid negotiated MTU (Maximum Transmission Unit) size."
        case .operationCancelled:
            return "The pending operation was cancelled before the peripheral answered it."
        }
    }
}
