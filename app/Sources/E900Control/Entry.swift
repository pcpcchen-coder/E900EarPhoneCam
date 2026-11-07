import AppKit
import Foundation

/// `E900Control` opens the SwiftUI app; `E900Control --accept …` runs the headless hardware
/// acceptance in the same binary (and therefore under the same bundle / Bluetooth usage text).
@main enum Entry {
    static func main() {
        let args = Array(CommandLine.arguments.dropFirst())
        guard args.contains("--accept") else { E900ControlApp.main(); return }
        if args.contains("--help") { print(AcceptanceOptions.usage); exit(0) }
        let options: AcceptanceOptions
        do { options = try AcceptanceOptions.parse(args) }
        catch { fputs("\(error.localizedDescription)\n\n\(AcceptanceOptions.usage)\n", stderr); exit(2) }
        Task { @MainActor in
            let code = await AcceptanceRunner(options: options).run()
            exit(code)
        }
        // CoreBluetooth delegates and Headset timers are scheduled on the main run loop.
        RunLoop.main.run()
    }
}
