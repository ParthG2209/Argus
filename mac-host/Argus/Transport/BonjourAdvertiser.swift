import Foundation
import os

class BonjourAdvertiser: NSObject, NetServiceDelegate {
    private let netService: NetService
    private var isAdvertising = false

    init(port: UInt16, name: String = "ArgusMac") {
        // "_argus._tcp." is the service type we will advertise
        self.netService = NetService(domain: "local.", type: "_argus._tcp.", name: name, port: Int32(port))
        super.init()
        self.netService.delegate = self
    }

    func start() {
        guard !isAdvertising else { return }
        NSLog("[Argus] Starting Bonjour advertiser...")
        netService.publish()
        isAdvertising = true
    }

    func stop() {
        guard isAdvertising else { return }
        NSLog("[Argus] Stopping Bonjour advertiser...")
        netService.stop()
        isAdvertising = false
    }

    // MARK: - NetServiceDelegate

    func netServiceDidPublish(_ sender: NetService) {
        NSLog("[Argus] Bonjour service published successfully: \(sender.name)")
    }

    func netService(_ sender: NetService, didNotPublish errorDict: [String : NSNumber]) {
        NSLog("[Argus] Failed to publish Bonjour service: \(errorDict)")
        isAdvertising = false
    }
}
