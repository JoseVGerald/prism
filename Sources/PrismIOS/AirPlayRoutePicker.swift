import SwiftUI
import AVKit

/// The iOS answer to the Mac's output picker.
///
/// The macOS app enumerates every output device with CoreAudio and *sets the
/// system default*. iOS has no equivalent and should not: routing there belongs
/// to the system, and an app that tried to seize it would be fighting Control
/// Centre. `AVRoutePickerView` is the sanctioned control — it lists AirPlay
/// targets, Bluetooth devices and the speaker, and hands the choice back to iOS.
///
/// Deliberately the real system control rather than a lookalike, so it stays
/// correct as routes appear and disappear.
struct AirPlayRoutePicker: UIViewRepresentable {
    func makeUIView(context: Context) -> AVRoutePickerView {
        let view = AVRoutePickerView()
        view.prioritizesVideoDevices = false
        view.activeTintColor = UIColor(Color.accentColor)
        view.tintColor = .white
        return view
    }

    func updateUIView(_ view: AVRoutePickerView, context: Context) {}
}
