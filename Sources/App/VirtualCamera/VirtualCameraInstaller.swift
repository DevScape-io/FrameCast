import Foundation
import SystemExtensions

/// Installs / removes the FrameCast camera system extension.
final class VirtualCameraInstaller: NSObject, ObservableObject, OSSystemExtensionRequestDelegate {
    @Published var status = ""
    @Published var isInstalled = false
    @Published var busy = false

    var extensionIdentifier: String {
        (Bundle.main.bundleIdentifier ?? "com.example.FrameCast") + ".CameraExtension"
    }

    var isInApplicationsFolder: Bool {
        Bundle.main.bundlePath.hasPrefix("/Applications/")
    }

    var isBundled: Bool {
        let url = Bundle.main.bundleURL.appendingPathComponent("Contents/Library/SystemExtensions/\(extensionIdentifier).systemextension")
        return FileManager.default.fileExists(atPath: url.path)
    }

    func refreshStatus() {
        isInstalled = VirtualCameraSink.findDevice() != nil
        if !isBundled {
            status = "This build doesn't include the camera extension (built with --no-vcam)."
        } else if isInstalled {
            status = "Installed — “\(VirtualCameraSink.deviceName)” is available in Zoom, Teams, Meet and other apps."
        } else if !isInApplicationsFolder {
            status = "Move FrameCast to the Applications folder, open it from there, then install."
        } else {
            status = "Not installed."
        }
    }

    func install() {
        guard isBundled else { refreshStatus(); return }
        busy = true
        status = "Requesting installation…"
        let request = OSSystemExtensionRequest.activationRequest(forExtensionWithIdentifier: extensionIdentifier, queue: .main)
        request.delegate = self
        OSSystemExtensionManager.shared.submitRequest(request)
    }

    func uninstall() {
        guard isBundled else { return }
        busy = true
        status = "Removing…"
        let request = OSSystemExtensionRequest.deactivationRequest(forExtensionWithIdentifier: extensionIdentifier, queue: .main)
        request.delegate = self
        OSSystemExtensionManager.shared.submitRequest(request)
    }

    // MARK: OSSystemExtensionRequestDelegate

    func request(_ request: OSSystemExtensionRequest,
                 actionForReplacingExtension existing: OSSystemExtensionProperties,
                 withExtension ext: OSSystemExtensionProperties) -> OSSystemExtensionRequest.ReplacementAction {
        .replace
    }

    func requestNeedsUserApproval(_ request: OSSystemExtensionRequest) {
        status = "Approve “FrameCast” in System Settings › General › Login Items & Extensions › Camera Extensions."
    }

    func request(_ request: OSSystemExtensionRequest, didFinishWithResult result: OSSystemExtensionRequest.Result) {
        busy = false
        if result == .willCompleteAfterReboot {
            status = "Done — restart your Mac to finish."
        } else {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { self.refreshStatus() }
            status = "Done."
        }
    }

    func request(_ request: OSSystemExtensionRequest, didFailWithError error: Error) {
        busy = false
        status = "Failed: \(error.localizedDescription)"
    }
}
