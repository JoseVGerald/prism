import SwiftUI

#if canImport(AppKit)
// Output switching is CoreAudio's default-device API. iOS has no equivalent and
// should not: routing there belongs to the system, so the iOS build uses
// AVRoutePickerView (see Sources/PrismIOS/AirPlayRoutePicker.swift) instead.

/// Speaker switcher for the sidebar. Bluetooth outputs sort to the top, since
/// those are the ones worth hopping between.
struct OutputPicker: View {
    @Bindable var model: AppModel

    @State private var open = false

    private var audio: AudioOutput { model.audio }

    var body: some View {
        Button {
            audio.refresh()
            open = true
        } label: {
            HStack(spacing: 8) {
                Image(systemName: icon).font(.system(size: 12)).frame(width: 15)
                Text(audio.current?.name ?? "Output")
                    .font(.caption).lineLimit(1)
                Spacer(minLength: 2)
                Image(systemName: "chevron.up.chevron.down")
                    .font(.system(size: 8)).foregroundStyle(.secondary)
            }
            .foregroundStyle(.secondary)
            .padding(.horizontal, 11).padding(.vertical, 7)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plainHit)
        .help("Where the sound goes")
        .popover(isPresented: $open, arrowEdge: .trailing) {
            VStack(alignment: .leading, spacing: 1) {
                ForEach(audio.devices) { device in
                    Button {
                        model.selectOutput(device)
                        open = false
                    } label: {
                        HStack(spacing: 9) {
                            Image(systemName: symbol(device))
                                .font(.system(size: 12)).frame(width: 16)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(device.name).font(.callout).lineLimit(1)
                                Text(device.transport).font(.caption2).foregroundStyle(.secondary)
                            }
                            Spacer(minLength: 12)
                            if device.id == audio.currentId {
                                Image(systemName: "checkmark")
                                    .font(.system(size: 10, weight: .semibold))
                                    .foregroundStyle(Color.accentColor)
                            }
                        }
                        .padding(.horizontal, 10).padding(.vertical, 7)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plainHit)
                }
                if audio.devices.isEmpty {
                    Text("No outputs found").font(.callout)
                        .foregroundStyle(.secondary).padding(12)
                }
                Divider().padding(.vertical, 4)
                Text("Paired speakers appear here once macOS connects them.")
                    .font(.caption2).foregroundStyle(.secondary)
                    .padding(.horizontal, 10).padding(.bottom, 8)
                    .frame(maxWidth: 230, alignment: .leading)
            }
            .padding(6)
            .frame(width: 258)
        }
    }

    private var icon: String {
        guard let c = audio.current else { return "speaker.wave.2" }
        return symbol(c)
    }

    private func symbol(_ d: OutputDevice) -> String {
        if d.isBluetooth { return "hifispeaker" }
        switch d.transport {
        case "AirPlay":  return "airplayaudio"
        case "Built-in": return "laptopcomputer"
        case "USB":      return "cable.connector"
        case "HDMI", "DisplayPort": return "tv"
        default:         return "speaker.wave.2"
        }
    }
}
#endif

/// Undo affordance for the last queue edit. Sits in the queue header so it is
/// next to the thing it undoes, and mirrors Cmd-Z.
struct UndoButton: View {
    @Bindable var model: AppModel

    var body: some View {
        if let label = model.engine.snapshot.undoLabel {
            Button {
                model.undoQueueEdit()
            } label: {
                Image(systemName: "arrow.uturn.backward")
                    .font(.system(size: 12))
                    .frame(width: 28, height: 28)
            }
            .buttonStyle(.plainHit)
            .glassEffect(.regular.interactive(), in: .circle)
            #if canImport(AppKit)
            .help("Undo \(label) (⌘Z)")
            #endif
            .transition(.opacity.combined(with: .scale))
        }
    }
}

/// Crossfade length, exposed where the transport is rather than buried.
struct CrossfadeControl: View {
    @Bindable var model: AppModel

    @State private var open = false

    var body: some View {
        Button { open = true } label: {
            Image(systemName: model.transitions.seconds > 0
                  ? "waveform.path.ecg" : "waveform.path")
                .font(.system(size: 13))
                .foregroundStyle(model.transitions.seconds > 0
                                 ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(.secondary))
                .frame(width: 30, height: 30)
        }
        .buttonStyle(PressableButtonStyle())
        .hoverBloom(scale: 1.08, radius: 12)
        .help("Transitions")
        .popover(isPresented: $open) {
            VStack(alignment: .leading, spacing: 12) {
                Text("Transitions").font(.headline)

                VStack(alignment: .leading, spacing: 5) {
                    HStack {
                        Text("Crossfade").font(.callout)
                        Spacer()
                        Text(model.transitions.seconds > 0
                             ? "\(Int(model.transitions.seconds))s" : "Off")
                            .font(.callout.monospacedDigit()).foregroundStyle(.secondary)
                    }
                    // Off, or six seconds and up. There is nothing between:
                    // a shorter overlap is not long enough to be a mix, and it
                    // leaves no room to hide a tempo bend, so the planner would
                    // quietly raise it anyway. Better that the control says so.
                    Slider(value: Binding(get: { model.transitions.seconds },
                                          set: { v in
                                              let r = v.rounded()
                                              model.transitions.seconds = r <= 0 ? 0 : max(r, Transitions.minimumBlend)
                                          }),
                           in: 0...16, step: 1)
                    Text("Overlaps tracks using a second hidden player. Costs a\nlittle extra CPU and network while a fade is armed.")
                        .font(.caption2).foregroundStyle(.secondary)
                }

                Divider()

                VStack(alignment: .leading, spacing: 5) {
                    Toggle("AutoMix", isOn: Binding(get: { model.transitions.autoMix },
                                                    set: { model.transitions.autoMix = $0 }))
                        .toggleStyle(.switch)
                        .controlSize(.mini)
                        .font(.callout)
                    Text("Sets the length from both tracks' tempos and bends them\ntowards one shared tempo, so the beats line up through the\noverlap. Falls back to a plain fade when a tempo is unknown.")
                        .font(.caption2).foregroundStyle(.secondary)

                    if model.transitions.autoMix {
                        Toggle("Bend the outgoing track", isOn: Binding(
                            get: { model.transitions.bendOutgoing },
                            set: { model.transitions.bendOutgoing = $0 }))
                            .toggleStyle(.switch)
                            .controlSize(.mini)
                            .font(.callout)
                            .padding(.top, 2)
                        Text("Lets the old song lean into the new one. Turn off if you\nhear it stutter — the beats still line up either way.")
                            .font(.caption2).foregroundStyle(.secondary)
                    }

                    if let plan = model.transitions.lastPlan, let beats = plan.beats {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Last: \(beats) beats · \(String(format: "%.1f", plan.duration))s")
                            if let ramp = plan.tempoRamp, !ramp.outgoingSteps.isEmpty {
                                Text(String(format: "Met at %.0f BPM · bent %.1f%%",
                                            ramp.meetingBPM, ramp.largestStretchPercent))
                            }
                        }
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(Color.accentColor)
                    }
                }

            }
            .padding(15)
            .frame(width: 290)
        }
    }
}
