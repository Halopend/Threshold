// ModulationPanels.swift — the Motion ▸ Music / LFOs / Routes editor surface.
//
// This is the user-facing home of the modulation system. All three subtabs
// edit the SAME two data models on the mirror:
//   • Routes  — the binding list: any source (audio.* or lfo.*) → any param.
//               "Music controls" and "attach an LFO to any control" are the
//               same list with a different source.
//   • LFOs    — the procedural oscillator bank (LFO.swift) that produces the
//               lfo.* sources, with a live waveform preview per oscillator.
//   • Music   — audio input on/off (via AudioActions) plus one-tap presets that
//               drop common audio→param routes into the Routes list.
//
// The mirror OWNS bindings/lfos (ParameterMirror); editor rows mutate them and
// republish the whole set (mirror-owned, so fine-grained edits never flicker
// against a stale snapshot). Nothing here computes lane math.

import SwiftUI
import ThresholdCore

// MARK: - AudioActions

/// Audio-input verbs the shell provides (start/stop the mic → audio.* signals).
/// Separate from routing: enabling audio only makes the audio.* SIGNALS live;
/// what they DO is whatever routes bind them to. Nil in shells without audio.
public struct AudioActions {
    public var isEnabled: () -> Bool
    public var setEnabled: (Bool) -> Void

    public init(isEnabled: @escaping () -> Bool, setEnabled: @escaping (Bool) -> Void) {
        self.isEnabled = isEnabled
        self.setEnabled = setEnabled
    }
}

// MARK: - Source vocabulary

/// Display metadata for the bindable signal sources the Routes picker offers.
/// (Hand signals have their own gesture UI; the routing list stays audio + LFO.)
enum ModulationSource {
    /// Audio features, in a musically sensible order.
    static let audio: [(id: SignalID, label: String)] = [
        (.audioBandLow, "Bass"),
        (.audioBandMid, "Mid"),
        (.audioBandHigh, "Treble"),
        (.audioRMS, "Level"),
        (.audioOnset, "Onset"),
        (.audioCentroid, "Brightness"),
    ]

    /// Human label for any bindable signal, preferring an authored LFO name.
    static func label(for id: SignalID, lfos: [LFOSpec]) -> String {
        if let a = audio.first(where: { $0.id == id }) { return "Audio · \(a.label)" }
        if let lfo = lfos.first(where: { $0.slot == id }) {
            let name = lfo.name.isEmpty ? lfoSlotLabel(id) : lfo.name
            return "LFO · \(name)"
        }
        if let i = SignalID.standardLFOs.firstIndex(of: id) {
            return "LFO · \(Self.lfoLetter(i)) (empty)"
        }
        return id.rawValue
    }

    static func lfoSlotLabel(_ id: SignalID) -> String {
        guard let i = SignalID.standardLFOs.firstIndex(of: id) else { return id.rawValue }
        return lfoLetter(i)
    }

    static func lfoLetter(_ index: Int) -> String {
        String(UnicodeScalar(UInt8(65 + min(max(index, 0), 25))))  // A, B, C…
    }
}

// MARK: - Bindable targets

/// A single addressable target: one component of one continuous param.
struct BindTarget: Identifiable, Hashable {
    let key: ParamKey
    let component: Int
    let label: String
    let range: ClosedRange<Float>
    var id: String { "\(key.rawValue)#\(component)" }
}

extension BindTarget {
    /// Every continuous (float/vector) param component in the catalog + arena —
    /// what the Routes target picker offers. Discrete kinds (bool/enum) are
    /// skipped: a continuous modulator on a toggle is rarely what's wanted.
    static func all(layout: CatalogLayout, dynamic: [CatalogEntry]) -> [BindTarget] {
        var out: [BindTarget] = []
        let axis = ["x", "y", "z", "w"]
        for entry in layout.entries + dynamic {
            let width: Int
            switch entry.spec.kind {
            case .float: width = 1
            case .float3: width = 3
            case .float4: width = 4
            case .bool, .enumeration: continue
            }
            for c in 0..<width {
                let label = width == 1 ? entry.spec.label : "\(entry.spec.label) · \(axis[c])"
                out.append(BindTarget(
                    key: entry.key, component: c, label: label, range: entry.spec.range))
            }
        }
        return out
    }
}

// MARK: - MusicSection (Motion ▸ Music)

/// Audio input control + one-tap presets that add audio→param routes. The
/// actual routing lives in the Routes subtab; this is the quick on-ramp.
public struct MusicSection: View {
    let mirror: ParameterMirror
    let layout: CatalogLayout
    let audio: AudioActions?

    public init(mirror: ParameterMirror, layout: CatalogLayout, audio: AudioActions?) {
        self.mirror = mirror
        self.layout = layout
        self.audio = audio
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: DS.Spacing.sm) {
            SectionHeader("Music", icon: "waveform")
            if let audio {
                Toggle("Listen to microphone", isOn: SwiftUI.Binding(
                    get: { audio.isEnabled() },
                    set: { audio.setEnabled($0) }))
                Text("Audio features (bass, level, onset…) become sources you can route to any control in the Routes tab.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                Text("Audio input isn't available in this build.")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }

            Divider().padding(.vertical, DS.Spacing.xxs)
            Text("Quick add").font(.caption).foregroundStyle(.secondary)
            let count = mirror.bindings.count
            HStack {
                Button {
                    addRoute(signal: .audioBandLow, key: .cameraDolly,
                             outLo: 1, outHi: 1.6, curve: .exponential(k: 1.6))
                } label: { Label("Bass → Dolly", systemImage: "plus.circle") }
                Button {
                    addRoute(signal: .audioRMS, key: .engineAOStrength,
                             outLo: 0, outHi: 0.8, curve: .smooth)
                } label: { Label("Level → AO", systemImage: "plus.circle") }
            }
            .buttonStyle(.borderless)
            .font(.caption)
            if count > 0 {
                Text("^[\(count) route](inflect: true) active — edit them in Routes.")
                    .font(.caption2).foregroundStyle(.tertiary)
            }
        }
        .moduleCard(.pink)
    }

    private func addRoute(
        signal: SignalID, key: ParamKey, outLo: Float, outHi: Float, curve: MappingCurve
    ) {
        guard layout.entry(for: key) != nil else { return }
        mirror.addBinding(ThresholdCore.Binding(
            signal: signal, param: key, lane: .music,
            mapping: SignalMapping(
                inputLo: 0, inputHi: 1, outputLo: outLo, outputHi: outHi,
                curve: curve, deadzone: 0.02),
            policy: .momentary))
    }
}

// MARK: - RoutesSection (Motion ▸ Routes)

/// The binding list: source → param, with mapping. The full modulation editor.
public struct RoutesSection: View {
    let mirror: ParameterMirror
    let layout: CatalogLayout

    public init(mirror: ParameterMirror, layout: CatalogLayout) {
        self.mirror = mirror
        self.layout = layout
    }

    private var targets: [BindTarget] {
        BindTarget.all(layout: layout, dynamic: mirror.dynamicEntries)
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: DS.Spacing.sm) {
            SectionHeader("Routes", icon: "point.topleft.down.to.point.bottomright.curvepath") {
                Button {
                    addRoute()
                } label: { Image(systemName: "plus") }
                .buttonStyle(.borderless)
            }
            if mirror.bindings.isEmpty {
                Text("No routes yet. Add one to drive any control from an audio band or an LFO.")
                    .font(.caption2).foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            ForEach(mirror.bindings) { route in
                RouteCard(route: route, mirror: mirror, targets: targets)
            }
        }
        .moduleCard(.teal)
    }

    private func addRoute() {
        // Default to the first LFO (or bass) → the first available target.
        let source = mirror.lfos.first?.slot ?? SignalID.standardLFOs.first ?? .audioBandLow
        let target = targets.first
        mirror.addBinding(ThresholdCore.Binding(
            signal: source,
            param: target?.key ?? .cameraOrbitYaw,
            component: target?.component ?? 0,
            lane: .music,
            mapping: SignalMapping(
                inputLo: -1, inputHi: 1,
                outputLo: target?.range.lowerBound ?? -0.5,
                outputHi: target?.range.upperBound ?? 0.5,
                curve: .linear, deadzone: 0),
            policy: .latched))
    }
}

/// One route: a compact card editing a single `Binding`.
private struct RouteCard: View {
    let route: ThresholdCore.Binding
    let mirror: ParameterMirror
    let targets: [BindTarget]

    /// A binding over one Float field of the route that republishes on change.
    private func field(_ kp: WritableKeyPath<ThresholdCore.Binding, Float>) -> SwiftUI.Binding<Float> {
        SwiftUI.Binding(
            get: { route[keyPath: kp] },
            set: { var r = route; r[keyPath: kp] = $0; mirror.updateBinding(r) })
    }

    private var currentTarget: BindTarget? {
        targets.first { $0.key == route.param && $0.component == route.component }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Spacing.xs) {
            // Row 1: source → target, remove.
            HStack(spacing: DS.Spacing.xs) {
                sourceMenu
                Image(systemName: "arrow.right").font(.caption2).foregroundStyle(.tertiary)
                targetMenu
                Spacer(minLength: 0)
                Button(role: .destructive) {
                    mirror.removeBinding(id: route.id)
                } label: { Image(systemName: "minus.circle") }
                .buttonStyle(.borderless)
            }
            // Row 2: response curve + strength.
            HStack(spacing: DS.Spacing.sm) {
                curveMenu
                Spacer(minLength: DS.Spacing.sm)
                Text("Amount").font(.caption2).foregroundStyle(.secondary)
                Slider(value: field(\.scale), in: 0...2)
                    .frame(maxWidth: 120)
            }
            // Row 3: output range (maps into the target's units).
            if let t = currentTarget {
                rangeRow(
                    "Output", lo: field(\.mapping.outputLo), hi: field(\.mapping.outputHi),
                    domain: t.range)
            }
            // Advanced: input range, deadzone, policy, lane.
            DisclosureGroup("Advanced") {
                VStack(alignment: .leading, spacing: DS.Spacing.xs) {
                    rangeRow(
                        "Input", lo: field(\.mapping.inputLo), hi: field(\.mapping.inputHi),
                        domain: -1...1)
                    HStack {
                        Text("Deadzone").font(.caption2).foregroundStyle(.secondary)
                        Slider(value: field(\.mapping.deadzone), in: 0...0.5)
                    }
                    Picker("Hold", selection: SwiftUI.Binding(
                        get: { route.policy },
                        set: { var r = route; r.policy = $0; mirror.updateBinding(r) })) {
                        Text("Momentary").tag(BindingPolicy.momentary)
                        Text("Latched").tag(BindingPolicy.latched)
                    }
                    .pickerStyle(.segmented)
                }
                .padding(.top, DS.Spacing.xxs)
            }
            .font(.caption2)
        }
        .padding(DS.Spacing.sm)
        .background(RoundedRectangle(cornerRadius: DS.Radius.inset).fill(.quaternary.opacity(0.3)))
    }

    private var sourceMenu: some View {
        Menu {
            Section("LFOs") {
                ForEach(SignalID.standardLFOs, id: \.self) { id in
                    Button(ModulationSource.label(for: id, lfos: mirror.lfos)) {
                        var r = route; r.signal = id; mirror.updateBinding(r)
                    }
                }
            }
            Section("Audio") {
                ForEach(ModulationSource.audio, id: \.id) { s in
                    Button("Audio · \(s.label)") {
                        var r = route; r.signal = s.id; mirror.updateBinding(r)
                    }
                }
            }
        } label: {
            chip(ModulationSource.label(for: route.signal, lfos: mirror.lfos), system: "dot.radiowaves.left.and.right")
        }
    }

    private var targetMenu: some View {
        Menu {
            ForEach(targets) { t in
                Button(t.label) {
                    var r = route; r.param = t.key; r.component = t.component
                    // Re-center output on the new target's range.
                    r.mapping.outputLo = t.range.lowerBound
                    r.mapping.outputHi = t.range.upperBound
                    mirror.updateBinding(r)
                }
            }
        } label: {
            chip(currentTarget?.label ?? route.param.rawValue, system: "slider.horizontal.3")
        }
    }

    private var curveMenu: some View {
        Menu {
            Button("Linear") { setCurve(.linear) }
            Button("Smooth") { setCurve(.smooth) }
            Button("Exponential") { setCurve(.exponential(k: 1.6)) }
            Button("Step") { setCurve(.step(count: 4)) }
            Button("Pulse") { setCurve(.pulse(threshold: 0.5)) }
        } label: {
            chip(curveLabel(route.mapping.curve), system: "function")
        }
    }

    private func setCurve(_ c: MappingCurve) {
        var r = route; r.mapping.curve = c; mirror.updateBinding(r)
    }

    private func curveLabel(_ c: MappingCurve) -> String {
        switch c {
        case .linear: return "Linear"
        case .smooth: return "Smooth"
        case .exponential: return "Exp"
        case .step: return "Step"
        case .pulse: return "Pulse"
        }
    }

    private func rangeRow(
        _ title: String, lo: SwiftUI.Binding<Float>, hi: SwiftUI.Binding<Float>,
        domain: ClosedRange<Float>
    ) -> some View {
        HStack(spacing: DS.Spacing.xs) {
            Text(title).font(.caption2).foregroundStyle(.secondary).frame(width: 48, alignment: .leading)
            Slider(value: lo, in: domain)
            Slider(value: hi, in: domain)
            Text(String(format: "%.2f…%.2f", lo.wrappedValue, hi.wrappedValue))
                .font(.caption2).monospacedDigit().foregroundStyle(.tertiary)
                .frame(width: 78, alignment: .trailing)
        }
    }

    private func chip(_ text: String, system: String) -> some View {
        Label(text, systemImage: system)
            .font(.caption2)
            .lineLimit(1)
            .padding(.horizontal, DS.Spacing.xs)
            .padding(.vertical, DS.Spacing.xxs)
            .background(RoundedRectangle(cornerRadius: DS.Radius.xs).fill(.quaternary.opacity(0.5)))
    }
}

// MARK: - LFOBankSection (Motion ▸ LFOs)

/// The procedural oscillator bank. Each LFO publishes an `lfo.*` source the
/// Routes tab can bind. Cards show a live waveform preview.
public struct LFOBankSection: View {
    let mirror: ParameterMirror

    public init(mirror: ParameterMirror) {
        self.mirror = mirror
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: DS.Spacing.sm) {
            SectionHeader("LFOs", icon: "waveform.path.ecg") {
                Button {
                    addLFO()
                } label: { Image(systemName: "plus") }
                .buttonStyle(.borderless)
                .disabled(mirror.nextFreeLFOSlot == nil)
            }
            if mirror.lfos.isEmpty {
                Text("No LFOs yet. Add one, shape its waveform, then route it to any control in Routes.")
                    .font(.caption2).foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            ForEach(mirror.lfos) { lfo in
                LFOCard(lfo: lfo, mirror: mirror)
            }
        }
        .moduleCard(.indigo)
    }

    private func addLFO() {
        guard let slot = mirror.nextFreeLFOSlot else { return }
        let letter = ModulationSource.lfoSlotLabel(slot)
        mirror.addLFO(LFOSpec(
            slot: slot, name: letter,
            components: [LFOComponent(wave: .sine, rateHz: 0.3, phase: 0, amplitude: 1)],
            bias: 0, enabled: true))
    }
}

/// One oscillator card: name/enable, live preview, component editor, bias.
private struct LFOCard: View {
    let lfo: LFOSpec
    let mirror: ParameterMirror

    private func update(_ mutate: (inout LFOSpec) -> Void) {
        var s = lfo; mutate(&s); mirror.updateLFO(s)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Spacing.xs) {
            HStack(spacing: DS.Spacing.xs) {
                Text(ModulationSource.lfoSlotLabel(lfo.slot))
                    .font(.caption2.monospaced()).foregroundStyle(.secondary)
                    .frame(width: 18)
                TextField("Name", text: SwiftUI.Binding(
                    get: { lfo.name }, set: { v in update { $0.name = v } }))
                    .textFieldStyle(.roundedBorder)
                Toggle("", isOn: SwiftUI.Binding(
                    get: { lfo.enabled }, set: { v in update { $0.enabled = v } }))
                    .labelsHidden()
                Button(role: .destructive) {
                    mirror.removeLFO(id: lfo.id)
                } label: { Image(systemName: "minus.circle") }
                .buttonStyle(.borderless)
            }

            WaveformPreview(spec: lfo)
                .frame(height: 44)
                .frame(maxWidth: .infinity)
                .background(RoundedRectangle(cornerRadius: DS.Radius.sm).fill(.black.opacity(0.25)))
                .opacity(lfo.enabled ? 1 : 0.4)

            ForEach(Array(lfo.components.enumerated()), id: \.offset) { index, _ in
                LFOComponentRow(
                    component: SwiftUI.Binding(
                        get: { lfo.components[index] },
                        set: { v in update {
                            if index < $0.components.count { $0.components[index] = v }
                        } }),
                    onRemove: lfo.components.count > 1 ? {
                        update { $0.components.remove(at: index) }
                    } : nil)
            }

            HStack {
                Button {
                    update { $0.components.append(LFOComponent(wave: .triangle, rateHz: 0.5)) }
                } label: { Label("Add wave", systemImage: "plus") }
                .buttonStyle(.borderless).font(.caption2)
                Spacer()
                Text("Bias").font(.caption2).foregroundStyle(.secondary)
                Slider(value: SwiftUI.Binding(
                    get: { lfo.bias }, set: { v in update { $0.bias = v } }), in: -1...1)
                    .frame(maxWidth: 110)
            }
        }
        .padding(DS.Spacing.sm)
        .background(RoundedRectangle(cornerRadius: DS.Radius.inset).fill(.quaternary.opacity(0.3)))
    }
}

/// One oscillator component: waveform, rate, phase, amplitude.
private struct LFOComponentRow: View {
    @SwiftUI.Binding var component: LFOComponent
    let onRemove: (() -> Void)?

    var body: some View {
        HStack(spacing: DS.Spacing.xs) {
            Menu {
                ForEach(LFOWave.allCases, id: \.self) { w in
                    Button(w.rawValue.capitalized) { component.wave = w }
                }
            } label: {
                Image(systemName: icon(component.wave)).frame(width: 22)
            }
            .buttonStyle(.borderless)
            labeledSlider("Rate", value: $component.rateHz, in: 0...4, suffix: "Hz")
            labeledSlider("Amp", value: $component.amplitude, in: 0...1)
            labeledSlider("Phase", value: $component.phase, in: 0...1)
            if let onRemove {
                Button(role: .destructive, action: onRemove) {
                    Image(systemName: "xmark.circle")
                }
                .buttonStyle(.borderless)
            }
        }
        .font(.caption2)
    }

    private func labeledSlider(
        _ title: String, value: SwiftUI.Binding<Float>, in range: ClosedRange<Float>,
        suffix: String = ""
    ) -> some View {
        VStack(spacing: 0) {
            Slider(value: value, in: range)
            Text("\(title) \(String(format: "%.2f", value.wrappedValue))\(suffix)")
                .font(.system(size: 9)).foregroundStyle(.tertiary).lineLimit(1)
        }
    }

    private func icon(_ w: LFOWave) -> String {
        switch w {
        case .sine: return "wave.3.right"
        case .triangle: return "triangle"
        case .saw: return "chevron.up"
        case .square: return "squareshape"
        case .noise: return "scribble.variable"
        }
    }
}

/// A live, scrolling plot of an LFO's combined output. Presentation only —
/// TimelineView drives a cosmetic animation; it feeds no simulation time.
private struct WaveformPreview: View {
    let spec: LFOSpec

    var body: some View {
        TimelineView(.animation) { context in
            Canvas { ctx, size in
                let now = context.date.timeIntervalSinceReferenceDate
                let window = 4.0                       // seconds shown across the width
                let samples = max(2, Int(size.width))
                var path = Path()
                for i in 0..<samples {
                    let frac = Double(i) / Double(samples - 1)
                    let t = now - window + frac * window
                    let v = spec.value(at: t, seed: 0)                 // −range…range
                    let y = size.height * (0.5 - CGFloat(max(-1.5, min(1.5, v))) * 0.32)
                    let x = frac * size.width
                    if i == 0 { path.move(to: CGPoint(x: x, y: y)) }
                    else { path.addLine(to: CGPoint(x: x, y: y)) }
                }
                // Zero line.
                var mid = Path()
                mid.move(to: CGPoint(x: 0, y: size.height / 2))
                mid.addLine(to: CGPoint(x: size.width, y: size.height / 2))
                ctx.stroke(mid, with: .color(.white.opacity(0.15)), lineWidth: 0.5)
                ctx.stroke(path, with: .color(.cyan), lineWidth: 1.5)
            }
        }
    }
}
