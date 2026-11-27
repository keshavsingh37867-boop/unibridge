import Combine
import Foundation
import IOKit
import IOKit.usb

/// Unified coordinator discovering Mac, USB/OTG Pendrives, Android (MTP & ADB), and iOS devices.
@MainActor
public final class DeviceManager: ObservableObject {
    public let driveMonitor = DriveMonitor()
    public let mtpService = AndroidMTPService()
    public let adbService = AndroidADBService()
    public let iosService = IOSDeviceService()

    @Published public private(set) var endpoints: [StorageEndpoint] = [StorageEndpoint.macHome()]
    @Published public private(set) var isScanning: Bool = false

    private var cancellables: Set<AnyCancellable> = []
    private var usbNotifyPort: IONotificationPortRef?
    private var usbAddedIterator: io_iterator_t = 0
    private var usbRemovedIterator: io_iterator_t = 0
    private var pendingScanTask: Task<Void, Never>?
    private var isStarted = false

    public init() {
        driveMonitor.$drives
            .dropFirst()
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                guard let self, !self.isScanning else { return }
                self.scheduleRefresh(delayMs: 250)
            }
            .store(in: &cancellables)
    }

    public func start() {
        guard !isStarted else { return }
        isStarted = true

        driveMonitor.start()
        iosService.startMonitoring { [weak self] in
            Task { @MainActor in
                self?.scheduleRefresh(delayMs: 350)
            }
        }
        startUSBHardwareWatcher()
        refreshAllDevices()
    }

    public func stop() {
        pendingScanTask?.cancel()
        driveMonitor.stop()
        iosService.stopMonitoring()
        stopUSBHardwareWatcher()
        isStarted = false
    }

    public func refreshAllDevices() {
        pendingScanTask?.cancel()
        pendingScanTask = Task { [weak self] in
            await self?.performRefresh()
        }
    }

    public func refreshNow() async {
        pendingScanTask?.cancel()
        await performRefresh()
    }

    public func scheduleRefresh(delayMs: UInt64 = 400) {
        pendingScanTask?.cancel()
        pendingScanTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: delayMs * 1_000_000)
            guard !Task.isCancelled else { return }
            await self?.performRefresh()
        }
    }

    public func addCustomFolderTarget(_ url: URL) {
        driveMonitor.addCustomFolderTarget(url)
        refreshAllDevices()
    }

    public func ejectDrive(_ drive: DriveInfo) async throws {
        try await driveMonitor.eject(drive: drive)
        refreshAllDevices()
    }

    private func performRefresh() async {
        isScanning = true
        defer { isScanning = false }

        driveMonitor.refreshDrives()
        let macEndpoint = StorageEndpoint.macHome()
        let pendriveEndpoints = driveMonitor.drives.map { StorageEndpoint.fromDrive($0) }

        async let iosList = iosService.discoverEndpoints()
        async let adbList = adbService.discoverEndpoints()
        async let mtpList = mtpService.discoverEndpoints()

        let (ios, adb, mtp) = await (iosList, adbList, mtpList)
        // Preserve previously discovered MTP endpoints if an active MTP transfer skipped the bus rescan.
        let effectiveMTP = mtpService.isTransferring && mtp.isEmpty
            ? endpoints.filter { $0.platform == .androidMTP }
            : mtp

        endpoints = [macEndpoint] + pendriveEndpoints + effectiveMTP + adb + ios
    }

    // MARK: - IOKit USB Attach / Detach Watcher

    private func startUSBHardwareWatcher() {
        guard usbNotifyPort == nil else { return }
        guard let port = IONotificationPortCreate(kIOMainPortDefault) else { return }
        usbNotifyPort = port
        IONotificationPortSetDispatchQueue(port, DispatchQueue.main)

        let selfPtr = Unmanaged.passUnretained(self).toOpaque()
        let callback: IOServiceMatchingCallback = { ctx, iterator in
            // Drain iterator so future notifications continue firing.
            while case let obj = IOIteratorNext(iterator), obj != 0 {
                IOObjectRelease(obj)
            }
            guard let ctx else { return }
            let manager = Unmanaged<DeviceManager>.fromOpaque(ctx).takeUnretainedValue()
            Task { @MainActor in
                manager.scheduleRefresh(delayMs: 1200)
            }
        }

        if let matchDict = IOServiceMatching("IOUSBHostDevice") {
            let kr = IOServiceAddMatchingNotification(port, kIOFirstMatchNotification, matchDict, callback, selfPtr, &usbAddedIterator)
            if kr == KERN_SUCCESS {
                while case let obj = IOIteratorNext(usbAddedIterator), obj != 0 {
                    IOObjectRelease(obj)
                }
            }
        }
        if let matchDict2 = IOServiceMatching("IOUSBHostDevice") {
            let kr = IOServiceAddMatchingNotification(port, kIOTerminatedNotification, matchDict2, callback, selfPtr, &usbRemovedIterator)
            if kr == KERN_SUCCESS {
                while case let obj = IOIteratorNext(usbRemovedIterator), obj != 0 {
                    IOObjectRelease(obj)
                }
            }
        }
    }

    private func stopUSBHardwareWatcher() {
        if usbAddedIterator != 0 {
            IOObjectRelease(usbAddedIterator)
            usbAddedIterator = 0
        }
        if usbRemovedIterator != 0 {
            IOObjectRelease(usbRemovedIterator)
            usbRemovedIterator = 0
        }
        if let port = usbNotifyPort {
            IONotificationPortDestroy(port)
            usbNotifyPort = nil
        }
    }
}
