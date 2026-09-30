//
//  CentralManager.swift
//  iOS-BLE-Library
//
//  Created by Nick Kibysh on 18/04/2023.
//

import Combine
#if MOCK_TRANSPORT
import CoreBluetoothMock
#else
import CoreBluetooth
#endif
import Foundation

// MARK: - Error

extension CentralManager {
    
	public enum Err: Error {
		case wrongManager
		case badState(CBManagerState)
		case unknownError

		public var localizedDescription: String {
			switch self {
			case .wrongManager:
				return "Incorrect manager instance provided. Delegate must be of type ReactiveCentralManagerDelegate."
			case .badState(let state):
				return "Bad state: \(state)."
			case .unknownError:
				return "An unknown error occurred."
			}
		}
	}
}

// MARK: - Observer

private class Observer: NSObject {
	@objc dynamic private weak var cm: CBCentralManager?
	private weak var publisher: CurrentValueSubject<Bool, Never>?
	private var observation: NSKeyValueObservation?

	init(cm: CBCentralManager, publisher: CurrentValueSubject<Bool, Never>) {
		self.cm = cm
		self.publisher = publisher
		super.init()
	}

	func setup() {
		observation = observe(\.cm?.isScanning, options: [.old, .new],
                               changeHandler: { _, change in
            change.newValue?.flatMap { [weak self] new in
                self?.publisher?.send(new)
            }
        })
	}
}

// MARK: - CentralManager

/// A Custom Central Manager class.
/// 
/// It wraps the standard CBCentralManager and has similar API. However, instead of using delegate, it uses publishers, thus bringing the reactive programming paradigm to the CoreBluetooth framework.
public class CentralManager {
	
    private let isScanningSubject = CurrentValueSubject<Bool, Never>(false)
	private let killSwitchSubject = PassthroughSubject<Void, Never>()
	private lazy var observer = Observer(cm: centralManager, publisher: isScanningSubject)

	/// The underlying CBCentralManager instance.
	public let centralManager: CBCentralManager
    
	/// The reactive delegate for the ``centralManager``.
	public let centralManagerDelegate: ReactiveCentralManagerDelegate

    // MARK: init
    
	/// Initializes a new instance of `CentralManager`.
	/// - Parameters:
	///   - centralManagerDelegate: The delegate for the reactive central manager. Default is `ReactiveCentralManagerDelegate()`.
	///   - queue: The queue to perform operations on. Default is the main queue.
	public init(
		centralManagerDelegate: ReactiveCentralManagerDelegate =
			ReactiveCentralManagerDelegate(), queue: DispatchQueue = .main, options: [String : Any]? = nil
	) {
		self.centralManagerDelegate = centralManagerDelegate
#if MOCK_TRANSPORT
		self.centralManager = CBMCentralManagerFactory.instance(
			delegate: centralManagerDelegate, queue: queue, options: options)
#else
		self.centralManager = CBCentralManager(
			delegate: centralManagerDelegate, queue: queue, options: options)
#endif
		observer.setup()
	}

	/// Initializes a new instance of `CentralManager` with an existing CBCentralManager instance.
	/// - Parameter centralManager: An existing CBCentralManager instance.
	/// - Throws: An error if the provided manager's delegate is not of type `ReactiveCentralManagerDelegate`.
	public init(centralManager: CBCentralManager) throws {
		guard
			let reactiveDelegate = centralManager.delegate
				as? ReactiveCentralManagerDelegate
		else {
			throw Err.wrongManager
		}

		self.centralManager = centralManager
		self.centralManagerDelegate = reactiveDelegate

		observer.setup()
	}

	public func getState() -> CBManagerState {
		return centralManager.state
	}

	/// Marks that restoration subscribers are ready and flushes any buffered restoration events.
	/// Call this after setting up subscriptions to ``restoredPeripheralsChannel`` to ensure
	/// no restoration events are lost due to initialization timing.
	public func markRestorationSubscribersReady() {
		centralManagerDelegate.markRestorationSubscribersReady()
	}
}

// MARK: Establishing or Canceling Connections with Peripherals

extension CentralManager {
	/// Establishes a connection with the specified peripheral.
	/// - Parameters:
	///   - peripheral: The peripheral to connect to.
	///   - options: Optional connection options.
	///   - keepPendingOnAbandon: What happens to the CoreBluetooth connect request when the
	///     returned publisher's subscription ends before, or after, the peripheral connects.
	///     See below. Arccos (Wave C3, CU-868m1mrjy): there is no default on purpose; every
	///     call site states which contract it relies on.
	/// - Returns: A publisher that emits the connected peripheral on successful connection.
	///            The publisher does not finish until the peripheral is successfully connected.
	///            If the peripheral was disconnected successfully, the publisher finishes without error.
	///            If the connection was unsuccessful or disconnection returns an error (e.g., peripheral disconnected unexpectedly),
	///            the publisher finishes with an error.
    ///
    /// Use ``CentralManager/connect(_:options:keepPendingOnAbandon:)`` to connect to a peripheral.
    ///    The returned publisher will emit the connected peripheral or an error if the connection fails.
    ///    The publisher will not complete until the peripheral is disconnected.
    ///    If the connection fails, or the peripheral is unexpectedly disconnected, the publisher will fail with an error.
    ///
    ///    ```swift
    ///    centralManager.connect(peripheral, keepPendingOnAbandon: true)
    ///        .sink { completion in
    ///            switch completion {
    ///            case .finished:
	///                print("Peripheral disconnected successfully")
	///            case .failure(let error):
	///                print("Error: \(error)")
	///            }
	///        } receiveValue: { peripheral in
	///            print("Peripheral connected: \(peripheral)")
	///        }
	///        .store(in: &cancellables)
	///    ```
	///
	/// ## The abandon policy
	///
	/// CoreBluetooth's connect request never times out: once issued it stays pending until the
	/// peripheral connects, the connect fails, or `cancelPeripheralConnection` is called. The
	/// publisher only *observes* that request, so the question is what happens to the request
	/// when the subscription goes away.
	///
	/// - `keepPendingOnAbandon: true`: nothing. The request stays pending, or the connection
	///   stays up, after the subscription is cancelled or ends. This is what a caller that only
	///   awaits the connect (`firstValue`, or a Combine `timeout` on the connect) needs: taking
	///   the first value cancels the subscription, and with auto-reconnect the pending request is
	///   how the OS finishes the job after the caller's own timeout gave up. Use this policy for
	///   every connect you intend to outlive its publisher, and disconnect through
	///   ``cancelPeripheralConnection(_:)``. The request is listed in ``connectInventory`` while
	///   CoreBluetooth holds it.
	/// - `keepPendingOnAbandon: false`: the subscription owns the connection. When it ends, by
	///   any route, `cancelPeripheralConnection` is issued, so that afterwards CoreBluetooth
	///   holds nothing for the peripheral on this publisher's behalf: cancelling the
	///   subscription while `.connecting` withdraws the pending request, cancelling it after the
	///   value disconnects the peripheral, and a completion (a connect failure, or a disconnect
	///   that fails the publisher) withdraws whatever the OS still holds, which under
	///   auto-reconnect is the armed reconnect. Do not combine this policy with `firstValue`:
	///   taking the value ends the subscription and disconnects the peripheral it just connected.
	///
	/// Before Wave C3 the library never cancelled the request, i.e. every connect behaved as
	/// `keepPendingOnAbandon: true` without saying so; the app's connect paths relied on that.
	public func connect(
		_ peripheral: CBPeripheral, options: [String: Any]? = nil, keepPendingOnAbandon: Bool
	) -> AnyPublisher<CBPeripheral, Error> {
		// Identity must be checked BEFORE surfacing the error: `disconnectedPeripheralsChannel`
		// carries every peripheral's disconnects, and throwing first meant an error-carrying
		// disconnect from an UNRELATED peripheral failed this peripheral's in-flight connect.
		// (`cancelPeripheralConnection(_:)` below always had the correct ordering.)
		let killSwitch = self.disconnectedPeripheralsChannel.tryFirst(where: { p in
			guard p.0.identifier == peripheral.identifier else {
				return false
			}
			if let e = p.2 {
				throw e
			}
			return true
		})

		// Arccos (Wave C3): with `keepPendingOnAbandon: false` the subscription owns the
		// connection, so its end, by cancellation or by completion, withdraws whatever
		// CoreBluetooth still holds. The two routes need two hooks: `autoconnect()` runs the
		// connectable's cancel only when the last subscriber cancels (on completion it just
		// releases the connection), and the completion hook never sees a cancellation. A cancel
		// on a peripheral CoreBluetooth holds nothing for (already `.disconnected`) is a no-op
		// that produces no callback, so running both for one subscription is harmless.
		let withdraw: (String) -> Void = { [centralManager] route in
			Logger.shared.i("Connect subscription for \(peripheral.identifier.uuidString) \(route) (state \(peripheral.state.rawValue)); cancelling the CoreBluetooth connection (keepPendingOnAbandon: false)", category: "CentralManager")
			centralManager.cancelPeripheralConnection(peripheral)
		}
		let onCancel: (() -> Void)? = keepPendingOnAbandon ? nil : { withdraw("was cancelled") }

		return self.connectedPeripheralChannel
			.filter { $0.0.identifier == peripheral.identifier }
			.tryMap { p in
				if let e = p.1 {
					throw e
				}

				return p.0
			}
			.prefix(untilUntilOutputOrCompletion: killSwitch)
			.handleEvents(receiveCompletion: { completion in
				guard !keepPendingOnAbandon else { return }
				withdraw("completed (\(completion))")
			})
			.bluetooth({
				self.centralManagerDelegate.connectInventory.record(
					peripheral, options: options,
					origin: .connect(keepPendingOnAbandon: keepPendingOnAbandon))
				self.centralManager.connect(peripheral, options: options)
				Logger.shared.i("Issued connect for \(peripheral.identifier.uuidString) (keepPendingOnAbandon: \(keepPendingOnAbandon)); CoreBluetooth now holds \(self.connectInventory.count) connect(s) for this app", category: "CentralManager")
			}, onCancel: onCancel)
            .autoconnect()
            .eraseToAnyPublisher()
	}

	/// Cancels the connection with the specified peripheral.
	/// - Parameter peripheral: The peripheral to disconnect from.
	/// - Returns: A publisher that emits the disconnected peripheral.
	public func cancelPeripheralConnection(_ peripheral: CBPeripheral) -> AnyPublisher<CBPeripheral, Error>
	{
		return self.disconnectedPeripheralsChannel
			.tryFilter { r in
				guard r.0.identifier == peripheral.identifier else {
					return false
				}

				if let e = r.2 {
					throw e
				} else {
					return true
				}
			}
			.map { $0.0 }
			.first()
            .bluetooth {
                self.centralManager.cancelPeripheralConnection(peripheral)
            }
            .autoconnect()
            .eraseToAnyPublisher()
	}
}

// MARK: Retrieving Lists of Peripherals

extension CentralManager {
	#warning("check `connect` method")		
	/// Returns a list of the peripherals connected to the system whose
	/// services match a given set of criteria.
	///
	/// The list of connected peripherals can include those that other apps
	/// have connected. You need to connect these peripherals locally using
	/// the `connect(_:options:)` method before using them.
	/// - Parameter serviceUUIDs: A list of service UUIDs, represented by
	///                           `CBUUID` objects.
	/// - Returns: A list of the peripherals that are currently connected
	///            to the system and that contain any of the services
	///            specified in the `serviceUUID` parameter.
	public func retrieveConnectedPeripherals(withServices identifiers: [CBUUID])
		-> [CBPeripheral]
	{
		centralManager.retrieveConnectedPeripherals(withServices: identifiers)
	}

	/// Returns a list of known peripherals by their identifiers.
	/// - Parameter identifiers: A list of peripheral identifiers
	///                          (represented by `NSUUID` objects) from which
	///                          ``CBPeripheral`` objects can be retrieved.
	/// - Returns: A list of peripherals that the central manager is able
	///            to match to the provided identifiers.
	public func retrievePeripherals(withIdentifiers identifiers: [UUID]) -> [CBPeripheral] {
		centralManager.retrievePeripherals(withIdentifiers: identifiers)
	}
}

// MARK: Scanning or Stopping Scans of Peripherals

extension CentralManager {
	#warning("Question: Should we throw an error if the scan is already running?")
	/// Initiates a scan for peripherals with the specified services.
	/// 
	/// Calling this method stops an ongoing scan if it is already running and finishes the publisher returned by ``scanForPeripherals(withServices:)``.
	/// 
	/// - Parameters:
	///   - services: The services to scan for.
	///   - options: A dictionary to customize the scan, such as specifying whether duplicate results should be reported.
	/// - Returns: A publisher that emits scan results or an error.
	public func scanForPeripherals(withServices services: [CBUUID]?, options: [String: Any]? = nil)
		-> AnyPublisher<ScanResult, Error>
	{
		stopScan()
		return centralManagerDelegate.stateSubject
			.tryFirst { state in
				guard let determined = state.ready else { return false }

				guard determined else { throw Err.badState(state) }
				return true
			}
			.flatMap { _ in
				// TODO: Check for mmemory leaks
				return self.centralManagerDelegate.scanResultSubject
					.setFailureType(to: Error.self)
			}
			.map { a in
				return a
			}
			.prefix(untilOutputFrom: killSwitchSubject)
			.mapError { [weak self] e in
				self?.stopScan()
				return e
			}
			.bluetooth({
				self.centralManager.scanForPeripherals(withServices: services, options: options)
			}, onCancel: { [centralManager] in
				// Arccos (Wave C3): a scan nobody is subscribed to would run the radio until the
				// next `stopScan()`. Runs when the last subscriber cancels (a cancelled sink or
				// task, or `firstValue` taking its value); the completion routes (`stopScan()`,
				// a state error) have already stopped the radio themselves. Stops CoreBluetooth
				// directly rather than through `stopScan()`, whose kill switch would finish
				// every other scan publisher too.
				centralManager.stopScan()
			})
            .autoconnect()
            .eraseToAnyPublisher()
	}

	/// Stops an ongoing scan for peripherals.
	/// Calling this method finishes the publisher returned by ``scanForPeripherals(withServices:)``.
	public func stopScan() {
		centralManager.stopScan()
		killSwitchSubject.send(())
	}
}

// MARK: Channels

extension CentralManager {
	/// A publisher that emits the state of the central manager.
	public var stateChannel: AnyPublisher<CBManagerState, Never> {
		centralManagerDelegate
			.stateSubject
			.eraseToAnyPublisher()
	}

	/// A publisher that emits the scanning state.
	public var isScanningChannel: AnyPublisher<Bool, Never> {
		isScanningSubject
			.eraseToAnyPublisher()
	}

	/// A publisher that emits scan results.
	public var scanResultsChannel: AnyPublisher<ScanResult, Never> {
		centralManagerDelegate.scanResultSubject
			.eraseToAnyPublisher()
	}

	/// A publisher that emits connected peripherals along with errors.
	public var connectedPeripheralChannel: AnyPublisher<(CBPeripheral, Error?), Never> {
		centralManagerDelegate.connectedPeripheralSubject
			.eraseToAnyPublisher()
	}

	/// A publisher that emits disconnected peripherals along with `isReconnecting` and errors.
	public var disconnectedPeripheralsChannel: AnyPublisher<(CBPeripheral, Bool, Error?), Never> {
		centralManagerDelegate.disconnectedPeripheralsSubject
			.eraseToAnyPublisher()
	}

	/// A publisher that emits the state-restoration dictionary from `willRestoreState`.
	public var restoredPeripheralsChannel: AnyPublisher<[String: Any], Never> {
		centralManagerDelegate.restoredPeripheralsSubject
			.eraseToAnyPublisher()
	}

	#if !os(macOS)
	/// Arccos (Wave C3): a publisher that emits a peripheral whenever its ANCS (Apple
	/// Notification Center Service) authorization changes; read `ancsAuthorized` on it. The
	/// system reports this for any connected peripheral the user toggles in Settings, not only
	/// ones connected with `CBConnectPeripheralOptionRequiresANCS`. Before Wave C3 the delegate
	/// method behind this channel was a `fatalError`.
	public var ancsAuthorizationChannel: AnyPublisher<CBPeripheral, Never> {
		centralManagerDelegate.ancsAuthorizationSubject
			.eraseToAnyPublisher()
	}
	#endif
}

// MARK: - Connect inventory (Arccos, Wave C3)

extension CentralManager {
	/// Every peripheral CoreBluetooth currently holds a connection, or a pending connect, for
	/// on this app's behalf, as far as this library can know: connects issued through
	/// ``connect(_:options:keepPendingOnAbandon:)`` in this process, plus handles state
	/// restoration handed back `.connecting` or `.connected`. Each record's ``ConnectRecord/state``
	/// is read from the handle when you call this, so `.connecting` is "pending right now".
	///
	/// Not included: connects issued directly on ``centralManager`` (the raw `CBCentralManager`),
	/// and connects whose `CBPeripheral` was released by everyone, which CoreBluetooth cancels
	/// on its own. Ordered by issue time.
	public var connectInventory: [ConnectRecord] {
		centralManagerDelegate.connectInventory.live
	}

	/// The subset of ``connectInventory`` CoreBluetooth has not connected yet: "what connects
	/// does iOS hold for us right now".
	public var pendingConnects: [ConnectRecord] {
		connectInventory.filter { $0.state == .connecting }
	}
}

// MARK: - State

extension CentralManager {
    
    /**
     Helper function to quickly ensure ``CentralManager`` is ready for use.
     
     As ``CentralManager`` is a wrapper around `CoreBluetooth`'s `CBCentralManager`, we must still abide by its requirements. The most important one being, to check whether its current state is valid in order to continue with proper BLE functions. As we know, BLE / `CoreBluetooth` might be unavailable for a variety of reasons, from the device's Bluetooth being turned off, to the current app not having Bluetooth permission, even up to hardware issues.
     
     - Tip: if you're setting up a ``CentralManager`` with a shared underlying `CBCentralManager` with other frameworks or areas of your app, and you'd like to retrieve a ``Peripheral`` that you're connected to via another "Manager" of some sort, waiting for ``isPoweredOn()`` before trying to find said ``Peripheral`` would be a good idea.
     - Throws: if ``CentralManager`` cannot be used for Bluetooth. In other words, if ``stateChannel`` returns anything other than `CBManagerState.poweredOn`.
     
     Sample Usage:
     ```swift
     let centralManager: CentralManager = // init CentralManager
     do {
        // Assumed async environment
        await centralManager.isPoweredOn()
        // Bluetooth available
     } catch let bleError {
        // Bluetooth unavailable
     }
     */
    public func isPoweredOn() async throws {
        let currentState = try await stateChannel
            // Wait for a state that is not subject to change quickly.
            .filter({ $0 != .resetting })
            .filter({ $0 != .unknown })
            .firstValue
        
        guard currentState == .poweredOn else {
            throw Err.badState(currentState)
        }
        return // System Ready / BLE Radio Available
    }
}
