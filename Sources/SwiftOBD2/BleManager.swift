// MARK: - BLEManager Class Documentation
/// The BLEManager class is a wrapper around the CoreBluetooth framework. It is responsible for managing the connection to the OBD2 adapter,
/// scanning for peripherals, and handling the communication with the adapter.
///
/// **Key Responsibilities:**
/// - Scanning for peripherals
/// - Connecting to peripherals
/// - Managing the connection state
/// - Handling the communication with the adapter
/// - Processing the characteristics of the adapter
/// - Sending messages to the adapter
/// - Receiving messages from the adapter
/// - Parsing the received messages
/// - Handling errors


import Foundation
import CoreBluetooth
import Combine
import OSLog

public enum ConnectionState {
    case disconnected
    case connectedToAdapter
    case connectedToVehicle
}

var debug = true

class BLEManager: NSObject, CBPeripheralProtocolDelegate, CBCentralManagerProtocolDelegate, CommProtocol {

    let logger = Logger(subsystem: "com.kemo.SmartOBD2", category: "BLEManager")
    static let RestoreIdentifierKey: String = "OBD2Adapter"

    // MARK: Properties
    @Published var connectionState: ConnectionState = .disconnected
    @Published var connectedPeripheral: CBPeripheralProtocol?

    var connectionStatePublisher: Published<ConnectionState>.Publisher { $connectionState }

    private var centralManager: CBCentralManagerProtocol!
    private var ecuReadCharacteristic: CBCharacteristic?
    private var ecuWriteCharacteristic: CBCharacteristic?

    private var buffer = Data()

    private var sendMessageCompletion: (([String]?, Error?) -> Void)?
    private var foundPeripheralCompletion: ((CBPeripheralProtocol?, Error?) -> Void)?
    private var connectionCompletion: ((CBPeripheralProtocol?, Error?) -> Void)?

    // MARK: - Initialization
    override init() {
        super.init()
        #if targetEnvironment(simulator)
        self.centralManager = CBCentralManagerMock(delegate: self, queue: nil, options: nil)
        #else
        self.centralManager = CBCentralManager(delegate: self, queue: .main, options: [CBCentralManagerOptionShowPowerAlertKey: true,
                                                                                   CBCentralManagerOptionRestoreIdentifierKey : BLEManager.RestoreIdentifierKey])
        #endif
    }

    // MARK: - Central Manager Control Methods

    func startScanning(_ serviceUUIDs: [CBUUID]?) {
        let scanOption = [CBCentralManagerScanOptionAllowDuplicatesKey: false]
        centralManager?.scanForPeripherals(withServices: serviceUUIDs, options: scanOption)
    }

    func stopScan(){
        centralManager?.stopScan()
    }

    func disconnectPeripheral() {
        guard let connectedPeripheral = connectedPeripheral else { return }
        centralManager.cancelPeripheralConnection(connectedPeripheral)
    }

    // MARK: - Central Manager Delegate Methods
    func didUpdateState(_ central: CBCentralManagerProtocol) {
        switch central.state {
        case .poweredOn:
            guard let device = connectedPeripheral else {
                startScanning([CBUUID(string: "FFE0"), CBUUID(string: "FFF0")])
                return
            }
            if debug {
                logger.debug("Bluetooth is On.")
            }
            connect(to: device)
        case .poweredOff:
            logger.warning("Bluetooth is currently powered off.")
            self.connectedPeripheral = nil
            self.connectionState = .disconnected
        case .unsupported:
            logger.error("This device does not support Bluetooth Low Energy.")
        case .unauthorized:
            logger.error("This app is not authorized to use Bluetooth Low Energy.")
        case .resetting:
            logger.warning("Bluetooth is resetting.")
        default:
            logger.error("Bluetooth is not powered on.")
            fatalError()
        }
    }

    func didDiscover(_ central: CBCentralManagerProtocol, peripheral: CBPeripheralProtocol, advertisementData: [String : Any], rssi: NSNumber) {
        connect(to: peripheral)
//        appendFoundPeripheral(peripheral: peripheral, advertisementData: advertisementData, rssi: rssi)
        if foundPeripheralCompletion != nil {
            foundPeripheralCompletion?(peripheral, nil)
        }
    }

    func connect(to peripheral: CBPeripheralProtocol) {
        if debug {
            logger.info("Connecting to: \(peripheral.name ?? "")")
        }
        centralManager.connect(peripheral, options: [CBConnectPeripheralOptionNotifyOnDisconnectionKey: true])
        if centralManager.isScanning {
            centralManager.stopScan()
        }
    }

    func didConnect(_ central: CBCentralManagerProtocol, peripheral: CBPeripheralProtocol) {
        if debug {
            logger.info("Connected to peripheral: \(peripheral.name ?? "Unnamed")")
        }
        connectedPeripheral = peripheral
        connectedPeripheral?.delegate = self
        connectedPeripheral?.discoverServices([CBUUID(string: "FFE0"), CBUUID(string: "FFF0")])
        connectionState = .connectedToAdapter
    }

    func scanForPeripheralAsync(timeout: TimeInterval) async throws -> CBPeripheralProtocol? {
        // returns a single peripheral with the specified services
        return try await Timeout(seconds: timeout) {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<CBPeripheralProtocol, Error>) in
                self.foundPeripheralCompletion = { peripheral, error in
                    if let peripheral = peripheral {
                        continuation.resume(returning: peripheral)
                    } else if let error = error {
                        continuation.resume(throwing: error)
                    }
                    self.foundPeripheralCompletion = nil
                }
                self.startScanning([CBUUID(string: "FFF0"), CBUUID(string: "FFE0")])
            }
        }
    }

    // MARK: - Peripheral Delegate Methods

    func didDiscoverServices(_ peripheral: CBPeripheralProtocol, error: Error?) {
        for service in peripheral.services ?? [] {
            print("Discovered service: \(service.uuid)")
            if service.uuid == CBUUID(string: "FFE0") {
                peripheral.discoverCharacteristics([CBUUID(string: "FFE1")], for: service)
            } else if service.uuid == CBUUID(string: "FFF0") {
                peripheral.discoverCharacteristics([CBUUID(string: "FFF1"), CBUUID(string: "FFF2")], for: service)
            } else {
                if connectionCompletion != nil {
                    connectionCompletion?(peripheral, nil)
                }
                peripheral.discoverCharacteristics(nil, for: service)
            }
        }
    }

    func didDiscoverCharacteristics(_ peripheral: CBPeripheralProtocol, service: CBService, error: Error?) {
        guard let characteristics = service.characteristics, !characteristics.isEmpty else {
            return
        }

        for characteristic in characteristics {
            if characteristic.properties.contains(.notify) {
                peripheral.setNotifyValue(true, for: characteristic)
            }
            if characteristic.uuid.uuidString == "FFE1" {
                self.ecuWriteCharacteristic = characteristic
                self.ecuReadCharacteristic = characteristic
            } else if characteristic.uuid.uuidString == "FFF1" {
                self.ecuReadCharacteristic = characteristic
            } else if characteristic.uuid.uuidString == "FFF2" {
                self.ecuWriteCharacteristic = characteristic
            }
        }

        if self.connectionCompletion != nil {
            self.connectionCompletion?(peripheral, nil)
        }
    }

    func didUpdateValue(_ peripheral: CBPeripheralProtocol, characteristic: CBCharacteristic, error: Error?) {
        if let error = error {
            logger.error("Error reading characteristic value: \(error.localizedDescription)")
            return
        }

        guard let characteristicValue = characteristic.value else {
            return
        }

        switch characteristic {
        case ecuReadCharacteristic:
            processReceivedData(characteristicValue, completion: sendMessageCompletion)

        default:
            guard let responseString = String(data: characteristicValue, encoding: .utf8) else {
                return
            }
            logger.info("Unknown characteristic: \(characteristic)\nResponse: \(responseString)")
        }
    }

    func didFailToConnect(_ central: CBCentralManagerProtocol, peripheral: CBPeripheralProtocol, error: Error?) {
        logger.error("Failed to connect to peripheral: \(peripheral.name ?? "Unnamed")")
        connectedPeripheral = nil
        disconnectPeripheral()
    }

    func didDisconnect(_ central: CBCentralManagerProtocol, peripheral: CBPeripheralProtocol, error: Error?) {
        logger.info("Disconnected from peripheral: \(peripheral.name ?? "Unnamed")")
        resetConfigure()
    }

    func willRestoreState(_ central: CBCentralManagerProtocol, dict: [String : Any]) {
        if let peripherals = dict[CBCentralManagerRestoredStatePeripheralsKey] as? [CBPeripheral] {
            logger.debug("Restoring peripheral: \(peripherals[0].name ?? "Unnamed")")
            peripherals[0].delegate = self
            connectedPeripheral = peripherals[0]
        }
    }

    func connectionEventDidOccur(_ central: CBCentralManagerProtocol, event: CBConnectionEvent, peripheral: CBPeripheralProtocol) {
        logger.error("Connection event occurred: \(event.rawValue)")
    }

    // MARK: - Async Methods

    func connectAsync() async throws {
        guard let peripheral = try await scanForPeripheralAsync(timeout: 5) else {
            throw BLEManagerError.peripheralNotFound
        }

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<CBPeripheralProtocol, Error>) in
            self.connectionCompletion = { peripheral, error in
                if let peripheral = peripheral {
                    continuation.resume(returning: peripheral)
                } else if let error = error {
                    continuation.resume(throwing: error)
                }
            }
            connect(to: peripheral)
        }
        connectionCompletion = nil
    }

    /// Sends a message to the connected peripheral and returns the response.
    /// - Parameter message: The message to send.
    /// - Returns: The response from the peripheral.
    /// - Throws:
    ///     `BLEManagerError.sendingMessagesInProgress` if a message is already being sent.
    ///     `BLEManagerError.missingPeripheralOrCharacteristic` if the peripheral or ecu characteristic is missing.
    ///     `BLEManagerError.incorrectDataConversion` if the data cannot be converted to ASCII.
    ///     `BLEManagerError.peripheralNotConnected` if the peripheral is not connected.
    ///     `BLEManagerError.timeout` if the operation times out.
    ///     `BLEManagerError.unknownError` if an unknown error occurs.
    func sendCommand(_ command: String) async throws -> [String] {
        // ... (sending message logic)
        if debug {
            logger.debug("Sending message: \(command)")
        }
        guard sendMessageCompletion == nil else {
            throw BLEManagerError.sendingMessagesInProgress
        }

        guard let connectedPeripheral = self.connectedPeripheral,
              let characteristic = self.ecuWriteCharacteristic,
              let data = "\(command)\r".data(using: .ascii) else {
            logger.error("Error: Missing peripheral or ecu characteristic.")
            throw BLEManagerError.missingPeripheralOrCharacteristic
        }
        return try await Timeout(seconds: 3) {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<[String], Error>) in
                // Set up a timeout timer
                self.sendMessageCompletion = { response, error in
                    if let response = response {
                        continuation.resume(returning: response)

                    } else if let error = error {
                        continuation.resume(throwing: error)
                    }
                }
                connectedPeripheral.writeValue(data, for: characteristic, type: .withResponse)
            }
        }
    }

    /// Processes the received data from the peripheral.
    /// - Parameters:
    ///  - data: The data received from the peripheral.
    ///  - completion: The completion handler to call when the data has been processed.
    func processReceivedData(_ data: Data, completion: (([String]?, Error?) -> Void)?) {
        buffer.append(data)

        guard let string = String(data: buffer, encoding: .utf8) else {
            buffer.removeAll()
            return
        }

        if string.contains(">") {
            var lines = string
                .components(separatedBy: .newlines)
                .filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

            // remove the last line
            lines.removeLast()
            if debug {
                logger.info("Response: \(lines)")
            }

            if sendMessageCompletion != nil {
                if lines[0].uppercased().contains("NO DATA") {
                    sendMessageCompletion?(nil, BLEManagerError.noData)
                } else {
                    sendMessageCompletion?(lines, nil)
                }
            }
            sendMessageCompletion = nil
            buffer.removeAll()
        }
    }

    /// Cancels the current operation and throws a timeout error.
    func Timeout<R>(
        seconds: TimeInterval,
        operation: @escaping @Sendable () async throws -> R
    ) async throws -> R {
        return try await withThrowingTaskGroup(of: R.self) { group in
            // Start actual work.
            group.addTask {
                let result = try await operation()
                try Task.checkCancellation()
                return result
            }
            // Start timeout child task.
            group.addTask {
                if seconds > 0 {
                    try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
                }
                try Task.checkCancellation()
                // We’ve reached the timeout.
                if self.foundPeripheralCompletion != nil {
                    self.foundPeripheralCompletion?(nil, BLEManagerError.scanTimeout)
                }
                throw BLEManagerError.timeout
            }
            // First finished child task wins, cancel the other task.
            let result = try await group.next()!
            group.cancelAll()
            return result
        }
    }

    func resetConfigure() {
        ecuReadCharacteristic = nil
        connectedPeripheral = nil
        connectionState = .disconnected
    }

    func demoModeSwitch(_ isDemoMode: Bool) {
        // switch to mock manager in demo mode
        switch isDemoMode {
        case true:
            disconnectPeripheral()
            centralManager = CBCentralManagerMock(delegate: self, queue: nil)
        case false:
            centralManager = CBCentralManager(delegate: self, queue: .main, options: [CBCentralManagerOptionShowPowerAlertKey: true,
                                                                                  CBCentralManagerOptionRestoreIdentifierKey : BLEManager.RestoreIdentifierKey])
        }
    }
}

// MARK: - CBCentralManagerDelegate, CBPeripheralDelegate
/// Extension to conform to CBCentralManagerDelegate and CBPeripheralDelegate
/// and handle the delegate methods.
extension BLEManager: CBCentralManagerDelegate, CBPeripheralDelegate {
    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        didDiscoverServices(peripheral, error: error)
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        didDiscoverCharacteristics(peripheral, service: service, error: error)
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        didUpdateValue(peripheral, characteristic: characteristic, error: error)
    }

    func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral, advertisementData: [String: Any], rssi RSSI: NSNumber) {
        didDiscover(central, peripheral: peripheral, advertisementData: advertisementData, rssi: RSSI)
    }

    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        didConnect(central, peripheral: peripheral)
    }

    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        didUpdateState(central)
    }

    func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        didFailToConnect(central, peripheral: peripheral, error: error)
    }

    func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        didDisconnect(central, peripheral: peripheral, error: error)
    }

    func centralManager(_ central: CBCentralManager, willRestoreState dict: [String : Any]) {
        willRestoreState(central, dict: dict)
    }
}

enum BLEManagerError: Error, CustomStringConvertible {
    case missingPeripheralOrCharacteristic
    case unknownCharacteristic
    case scanTimeout
    case sendMessageTimeout
    case stringConversionFailed
    case noData
    case incorrectDataConversion
    case peripheralNotConnected
    case sendingMessagesInProgress
    case timeout
    case peripheralNotFound

    public var description: String {
        switch self {
        case .missingPeripheralOrCharacteristic:
            return "Error: Device not connected. Make sure the device is correctly connected."
        case .scanTimeout:
            return "Error: Scan timed out. Please try to scan again or check the device's Bluetooth connection."
        case .sendMessageTimeout:
            return "Error: Send message timed out. Please try to send the message again or check the device's Bluetooth connection."
        case .stringConversionFailed:
            return "Error: Failed to convert string. Please make sure the string is in the correct format."
        case .noData:
            return "Error: No Data"
        case .unknownCharacteristic:
            return "Error: Unknown characteristic"
        case .incorrectDataConversion:
            return "Error: Incorrect data conversion"
        case .peripheralNotConnected:
            return "Error: Peripheral not connected"
        case .sendingMessagesInProgress:
            return "Error: Sending messages in progress"
        case .timeout:
            return "Error: Timeout"
        case .peripheralNotFound:
            return "Error: Peripheral not found"
        }
    }
}

//func appendFoundPeripheral(peripheral: CBPeripheralProtocol, advertisementData: [String : Any], rssi: NSNumber) {
//    if rssi.intValue >= 0 { return }
//    let peripheralName = advertisementData[CBAdvertisementDataLocalNameKey] as? String ?? nil
//    var _name = "NoName"
//
//    if peripheralName != nil {
//        _name = String(peripheralName!)
//    } else if peripheral.name != nil {
//        _name = String(peripheral.name!)
//    }
//
//    let foundPeripheral: Peripheral = Peripheral(_peripheral: peripheral,
//                                                 _name: _name,
//                                                 _advData: advertisementData,
//                                                 _rssi: rssi,
//                                                 _discoverCount: 0)
//
//    if let index = foundPeripherals.firstIndex(where: { $0.peripheral.identifier.uuidString == peripheral.identifier.uuidString }) {
//        if foundPeripherals[index].discoverCount % 50 == 0 {
//            foundPeripherals[index].name = _name
//            foundPeripherals[index].rssi = rssi.intValue
//            foundPeripherals[index].discoverCount += 1
//        } else {
//            foundPeripherals[index].discoverCount += 1
//        }
//    } else {
//        foundPeripherals.append(foundPeripheral)
//    }
//}
