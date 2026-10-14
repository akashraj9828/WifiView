import CoreLocation
import CoreWLAN
import Foundation

setvbuf(stdout, nil, _IOLBF, 0)

guard let iface = CWWiFiClient.shared().interface() else {
    FileHandle.standardError.write("no wifi interface\n".data(using: .utf8)!)
    exit(1)
}

let outLock = NSLock()
func emit(_ obj: [String: Any]) {
    guard let d = try? JSONSerialization.data(withJSONObject: obj),
          let s = String(data: d, encoding: .utf8) else { return }
    outLock.lock(); print(s); outLock.unlock()
}

func now() -> Double { Date().timeIntervalSince1970 }

// Intervals in ms, overridable via env (set by server.js).
func envMs(_ k: String, _ def: Double) -> Double {
    (ProcessInfo.processInfo.environment[k].flatMap(Double.init) ?? def) / 1000
}
let rssiInterval = max(0.01, envMs("RSSI_MS", 250))
let scanGap = max(0, envMs("SCAN_GAP_MS", 1000))

// macOS only reveals SSIDs/BSSIDs to processes with Location authorization.
// For a CLI tool the grant is attributed to the terminal app that launched it.
final class Loc: NSObject, CLLocationManagerDelegate {
    let mgr = CLLocationManager()
    func start() {
        mgr.delegate = self
        if mgr.authorizationStatus == .notDetermined { mgr.requestAlwaysAuthorization() }
    }
    var status: Int { Int(mgr.authorizationStatus.rawValue) }  // 0 undetermined, 2 denied, 3/4 granted
    func locationManagerDidChangeAuthorization(_ m: CLLocationManager) {}
}
let loc = Loc()
loc.start()

// Slow path: full scan of nearby networks (~2-4s each).
DispatchQueue(label: "scan").async {
    while true {
        if let nets = try? iface.scanForNetworks(withSSID: nil) {
            let list: [[String: Any]] = nets.map { n in
                [
                    "ssid": n.ssid ?? "",
                    "bssid": n.bssid ?? "",
                    "rssi": n.rssiValue,
                    "channel": n.wlanChannel?.channelNumber ?? 0,
                    "band": n.wlanChannel?.channelBand.rawValue ?? 0,
                    "width": n.wlanChannel?.channelWidth.rawValue ?? 0,
                ]
            }
            emit(["type": "scan", "t": now(), "nets": list])
        }
        Thread.sleep(forTimeInterval: scanGap)
    }
}

// Fast path: connected AP RSSI/noise, on its own thread so the main run loop can serve CoreLocation.
Thread.detachNewThread {
    while true {
        emit([
            "type": "rssi",
            "t": now(),
            "rssi": iface.rssiValue(),
            "noise": iface.noiseMeasurement(),
            "channel": iface.wlanChannel()?.channelNumber ?? 0,
            "txRate": iface.transmitRate(),
            "ssid": iface.ssid() ?? "",
            "bssid": iface.bssid() ?? "",
            "band": iface.wlanChannel()?.channelBand.rawValue ?? 0,
            "width": iface.wlanChannel()?.channelWidth.rawValue ?? 0,
            "phy": iface.activePHYMode().rawValue,
            "security": iface.security().rawValue,
            "country": iface.countryCode() ?? "",
            "iface": iface.interfaceName ?? "",
            "auth": loc.status,
        ])
        Thread.sleep(forTimeInterval: rssiInterval)
    }
}

RunLoop.main.run()
