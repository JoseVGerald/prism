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
                Text(audio.playingName)
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
                // A click on a row adds it to what is playing or takes it
                // away, like the AirPlay list in Music. It used to switch to
                // that output alone, with adding one tucked into a small
                // circle at the far edge — picking a second pair of
                // headphones silently dropped the first.
                ForEach(audio.devices) { device in
                    let on = audio.playing.contains { $0.id == device.id }
                    OutputRow(device: device, symbol: symbol(device), on: on,
                              sole: on && audio.playing.count == 1) {
                        model.toggleOutput(device)
                    } only: {
                        model.selectOutput(device)
                        open = false
                    }
                }
                if audio.devices.isEmpty {
                    Text("No outputs found").font(.callout)
                        .foregroundStyle(.secondary).padding(12)
                }
                Divider().padding(.vertical, 4)
                Text("Tick as many as you like to play on all of them at once — two pairs of headphones, or headphones and a speaker. “Only” plays on just that one. Bluetooth runs a little behind wired speakers, so in one room those can echo. Paired devices appear once macOS connects them.")
                    .font(.caption2).foregroundStyle(.secondary)
                    .padding(.horizontal, 10).padding(.bottom, 8)
                    .frame(maxWidth: 240, alignment: .leading)
            }
            .padding(6)
            .frame(width: 268)
        }
    }

    private var icon: String {
        if audio.playing.count > 1 { return "hifispeaker.2" }
        guard let c = audio.current else { return "speaker.wave.2" }
        return symbol(c)
    }

    private func symbol(_ d: OutputDevice) -> String {
        if d.isBluetooth {
            let name = d.name.lowercased()
            if name.contains("airpods max") { return "airpodsmax" }
            if name.contains("airpods pro") { return "airpodspro" }
            if name.contains("airpods") { return "airpods" }
            if ["headphone", "wh-", "buds", "beats"].contains(where: name.contains) { return "headphones" }
            return "hifispeaker"
        }
        switch d.transport {
        case "AirPlay":  return "airplayaudio"
        case "Built-in": return "laptopcomputer"
        case "USB":      return "cable.connector"
        case "HDMI", "DisplayPort": return "tv"
        default:         return "speaker.wave.2"
        }
    }
}

/// One output in the picker: a tick for "playing here", and on hover an
/// "Only" for switching everything to it in one click.
private struct OutputRow: View {
    let device: OutputDevice
    let symbol: String
    let on: Bool
    /// The one output playing. It stays ticked — there is always somewhere
    /// for the sound to go — and "Only" would change nothing.
    let sole: Bool
    let toggle: () -> Void
    let only: () -> Void

    @State private var hovering = false

    var body: some View {
        HStack(spacing: 0) {
            Button(action: toggle) {
                HStack(spacing: 9) {
                    Image(systemName: on ? "checkmark.circle.fill" : "circle")
                        .font(.system(size: 15))
                        .foregroundStyle(on ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(.tertiary))
                        .frame(width: 18)
                    Image(systemName: symbol)
                        .font(.system(size: 12)).frame(width: 16)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(device.name).font(.callout).lineLimit(1)
                        Text(device.transport).font(.caption2).foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 8)
                }
                .padding(.leading, 8).padding(.vertical, 7)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plainHit)
            .help(sole ? "Playing here" : on ? "Stop playing here" : "Also play here")

            if !sole {
                Button("Only", action: only)
                    .buttonStyle(.plainHit)
                    .font(.caption.weight(.medium))
                    .padding(.horizontal, 9).padding(.vertical, 4)
                    .background(Capsule().fill(.white.opacity(0.12)))
                    .opacity(hovering ? 1 : 0)
                    .help("Play only here")
                    .padding(.trailing, 8)
            }
        }
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous)
            .fill(.white.opacity(hovering ? 0.07 : 0)))
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.12), value: hovering)
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
                    Picker("", selection: Binding(get: { model.transitions.style },
                                                  set: { model.transitions.style = $0 })) {
                        Text("Switch").tag(Transitions.Style.switchCut)
                        Text("Blend").tag(Transitions.Style.blend)
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    Text(model.transitions.style == .switchCut
                         ? "Like a DJ switch: the next song sneaks in under this one for\nfour bars, then everything swaps on the one — the new song\ncoming in at its drop. Tempos lock at 1:1, 2:1 or 3:2."
                         : "A long crossfade: both songs meet in the middle and the\nnew one gradually takes over.")
                        .font(.caption2).foregroundStyle(.secondary)
                        .padding(.bottom, 4)
                    HStack {
                        Text(model.transitions.style == .switchCut ? "Switch" : "Crossfade").font(.callout)
                        Spacer()
                        Text(model.transitions.seconds > 0
                             ? (model.transitions.style == .switchCut
                                ? "\(Int(model.transitions.seconds))s before the end"
                                : "\(Int(model.transitions.seconds))s")
                             : "Off")
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
                           in: 0...Transitions.maximumBlend, step: 1)
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
                    Text("Matches both tracks' tempos and lines their beats up\nthrough the overlap. Prism learns each song's tempo by\nlistening to its first and last minute — the recording\nindicator shows then. \(model.tempoMemory.count) songs learned so far; a song\nnot heard yet falls back to a plain fade.")
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
