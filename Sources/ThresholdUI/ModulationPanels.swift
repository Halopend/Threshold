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
import ThresholdShaderIR

// MARK: - AudioActions

/// Audio-input verbs the shell provides (start/stop the mic → audio.* signals).
/// Separate from routing: enabling audio only makes the audio.* SIGNALS live;
/// what they DO is whatever routes bind them to. Nil in shells without audio.
public struct AudioActions {
    public var isEnabled: () -> Bool
    public var setEnabled: (Bool) -> Void
    /// Push a new Focus Band to the mic analyzer AND the mirror (the app shell
    /// owns both). Nil in shells that predate the feature — the editor falls
    /// back to `mirror.setFocusBand` alone (no live DSP effect).
    public var setFocusBand: ((AudioFocusBand) -> Void)?

    public init(
        isEnabled: @escaping () -> Bool,
        setEnabled: @escaping (Bool) -> Void,
        setFocusBand: ((AudioFocusBand) -> Void)? = nil
    ) {
        self.isEnabled = isEnabled
        self.setEnabled = setEnabled
        self.setFocusBand = setFocusBand
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
        (.audioBandUser, "Focus Band"),
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
    /// The DE this target belongs to (`nil` = universal: engine/color/camera/
    /// warp). Drives the Routes fractal filter.
    let fractalKey: String?
    var id: String { "\(key.rawValue)#\(component)" }
}

extension BindTarget {
    /// Every continuous (float/vector) param component in the catalog + arena —
    /// what the Routes target picker offers. The startup catalog registers ALL
    /// built-in DEs' params, so this already spans every fractal; the Routes
    /// filter narrows it to the active one by default. Discrete kinds
    /// (bool/enum) are skipped: a continuous modulator on a toggle is rarely
    /// what's wanted.
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
                    key: entry.key, component: c, label: label, range: entry.spec.range,
                    fractalKey: fractalKey(for: entry.key)))
            }
        }
        return out
    }

    /// The DE key embedded in a `de.<deKey>.<name>` param key, else nil.
    static func fractalKey(for key: ParamKey) -> String? {
        let parts = key.rawValue.split(separator: ".")
        guard parts.count >= 2, parts[0] == "de" else { return nil }
        return String(parts[1])
    }

    /// Human name for a fractal section header (falls back to the raw key).
    static func fractalDisplayName(_ deKey: String) -> String {
        DERegistry.descriptor(forKey: deKey)?.displayName ?? deKey
    }

    /// Group targets into menu sections: General (universal) first, then the
    /// active fractal, then the rest alphabetically.
    static func grouped(_ targets: [BindTarget], activeFractal: String)
        -> [(title: String, targets: [BindTarget])] {
        let byFractal = Dictionary(grouping: targets, by: \.fractalKey)
        var sections: [(String, [BindTarget])] = []
        if let universal = byFractal[nil], !universal.isEmpty {
            sections.append(("General", universal))
        }
        if let active = byFractal[activeFractal], !active.isEmpty {
            sections.append((fractalDisplayName(activeFractal), active))
        }
        let others = byFractal.keys
            .compactMap { $0 }
            .filter { $0 != activeFractal }
            .sorted { fractalDisplayName($0) < fractalDisplayName($1) }
        for key in others {
            if let ts = byFractal[key], !ts.isEmpty {
                sections.append((fractalDisplayName(key), ts))
            }
        }
        return sections
    }
}

// MARK: - MusicSection (Motion ▸ Music)

/// The audio on-ramp: mic toggle, a LIVE meter (so it's obvious the mic is
/// heard), the tunable Focus Band, and one-tap presets/quick-adds that drop
/// audio→param routes. The routes themselves are ordinary `Binding`s edited in
/// the Routes subtab; this pane is the quick, visual way in.
public struct MusicSection: View {
    let mirror: ParameterMirror
    let layout: CatalogLayout
    let audio: AudioActions?

    public init(mirror: ParameterMirror, layout: CatalogLayout, audio: AudioActions?) {
        self.mirror = mirror
        self.layout = layout
        self.audio = audio
    }

    private var micOn: Bool { audio?.isEnabled() ?? false }

    /// Music-lane routes fed by an audio source (what the presets manage —
    /// LFO routes on the music lane are left alone).
    private var audioRouteCount: Int {
        let audioIDs = Set(ModulationSource.audio.map(\.id))
        return mirror.bindings.filter { audioIDs.contains($0.signal) && $0.lane == .music }.count
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: DS.Spacing.sm) {
            SectionHeader("Music", icon: "waveform")
            if let audio {
                Toggle("Listen to microphone", isOn: SwiftUI.Binding(
                    get: { audio.isEnabled() },
                    set: { audio.setEnabled($0) }))
            } else {
                Text("Audio input isn't available in this build.")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }

            // Live meter — the "is the mic working?" answer at a glance.
            AudioMeterView(
                levels: mirror.audioLevels, active: micOn,
                focusEnabled: mirror.focusBand.enabled)

            if audio != nil {
                Divider().padding(.vertical, DS.Spacing.xxs)
                FocusBandCard(mirror: mirror, audio: audio, addRoute: addRoute)

                Divider().padding(.vertical, DS.Spacing.xxs)
                presetSection

                Divider().padding(.vertical, DS.Spacing.xxs)
                quickAddSection
            }
        }
        .moduleCard(.pink)
    }

    // MARK: Presets (recipe bundles)

    private var presetSection: some View {
        VStack(alignment: .leading, spacing: DS.Spacing.xs) {
            HStack {
                Text("Presets").font(.caption).foregroundStyle(.secondary)
                Spacer()
                if audioRouteCount > 0 {
                    Button(role: .destructive) {
                        clearAudioRoutes()
                    } label: { Label("Clear", systemImage: "trash").font(.caption2) }
                    .buttonStyle(.borderless)
                }
            }
            Text("One tap recreates a classic look — layer them, then fine-tune in Routes.")
                .font(.caption2).foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)
            LazyVGrid(
                columns: [GridItem(.adaptive(minimum: 108), spacing: DS.Spacing.xs)],
                spacing: DS.Spacing.xs
            ) {
                ForEach(MusicPreset.builtIn) { preset in
                    Button {
                        install(preset)
                    } label: {
                        Label(preset.name, systemImage: preset.icon)
                            .font(.caption2)
                            .frame(maxWidth: .infinity)
                            .lineLimit(1).minimumScaleFactor(0.8)
                    }
                    .buttonStyle(.bordered)
                    .help(preset.summary)
                }
            }
        }
    }

    // MARK: Quick add (single routes)

    private var quickAddSection: some View {
        VStack(alignment: .leading, spacing: DS.Spacing.xs) {
            Text("Quick add").font(.caption).foregroundStyle(.secondary)
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
            if audioRouteCount > 0 {
                Text("^[\(audioRouteCount) music route](inflect: true) active — edit them in Routes.")
                    .font(.caption2).foregroundStyle(.tertiary)
            }
        }
    }

    // MARK: Mutation

    /// Add (or replace, if the same source→target already exists) one route.
    private func addRoute(
        signal: SignalID, key: ParamKey, outLo: Float, outHi: Float,
        curve: MappingCurve, component: Int = 0
    ) {
        guard let entry = layout.entry(for: key) else { return }
        let binding = ThresholdCore.Binding(
            signal: signal, param: key, component: component, lane: .music,
            mapping: SignalMapping(
                inputLo: 0, inputHi: 1,
                outputLo: entry.spec.range.clamp(outLo),
                outputHi: entry.spec.range.clamp(outHi),
                curve: curve, deadzone: 0.02),
            policy: .momentary)
        mirror.setBindings(replacing: [binding], in: mirror.bindings)
    }

    /// Layer a preset's routes in, idempotently (re-tapping the same preset
    /// won't duplicate; different presets stack).
    private func install(_ preset: MusicPreset) {
        let incoming = preset.bindings(layout: layout)
        guard !incoming.isEmpty else { return }
        mirror.setBindings(replacing: incoming, in: mirror.bindings)
    }

    /// Drop only the AUDIO-fed music routes (LFO routes on the music lane and
    /// any gesture bindings survive).
    private func clearAudioRoutes() {
        let audioIDs = Set(ModulationSource.audio.map(\.id))
        mirror.setBindings(mirror.bindings.filter {
            !(audioIDs.contains($0.signal) && $0.lane == .music)
        })
    }
}

// MARK: - Route replace helper

extension ParameterMirror {
    /// Replace any existing binding sharing a (signal, param, component) target
    /// with the incoming one, then append the rest — so quick-adds/presets are
    /// idempotent instead of piling up duplicate routes.
    func setBindings(replacing incoming: [ThresholdCore.Binding], in current: [ThresholdCore.Binding]) {
        struct Target: Hashable { let s: SignalID; let p: ParamKey; let c: Int }
        let keys = Set(incoming.map { Target(s: $0.signal, p: $0.param, c: $0.component) })
        let kept = current.filter { !keys.contains(Target(s: $0.signal, p: $0.param, c: $0.component)) }
        setBindings(kept + incoming)
    }
}

extension ClosedRange where Bound == Float {
    /// Clamp a value into the range (used to keep preset outputs in bounds even
    /// if a recipe's nominal value overshoots a param's declared range).
    func clamp(_ v: Float) -> Float { Swift.min(Swift.max(v, lowerBound), upperBound) }
}

// MARK: - AudioMeterView

/// A compact bank of live level bars — Bass / Mid / Treble / Level / Focus /
/// Onset — driven by the mirror's `audioLevels` (~30 Hz observable readback, no
/// TimelineView needed). Dimmed and flat when the mic is off.
struct AudioMeterView: View {
    let levels: AudioLevels
    let active: Bool
    let focusEnabled: Bool

    private var bars: [(label: String, level: Float, color: Color, live: Bool)] {
        [
            ("Bass", levels.bandLow, .blue, true),
            ("Mid", levels.bandMid, .green, true),
            ("Treble", levels.bandHigh, .yellow, true),
            ("Level", levels.rms, .pink, true),
            ("Focus", levels.bandUser, .purple, focusEnabled),
            ("Onset", levels.onset, .orange, true),
        ]
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .bottom, spacing: DS.Spacing.xs) {
                ForEach(Array(bars.enumerated()), id: \.offset) { _, bar in
                    MeterBar(
                        label: bar.label,
                        level: active && bar.live ? bar.level : 0,
                        color: bar.color,
                        dim: !active || !bar.live)
                }
            }
            if !active {
                Text("Turn on the mic to see levels move.")
                    .font(.caption2).foregroundStyle(.tertiary)
            }
        }
    }
}

/// One vertical level bar with a caption. Fixed bar height (no GeometryReader),
/// fill proportional to a 0…1 level.
private struct MeterBar: View {
    let label: String
    let level: Float
    let color: Color
    let dim: Bool
    private let barHeight: CGFloat = 40

    var body: some View {
        VStack(spacing: 2) {
            ZStack(alignment: .bottom) {
                RoundedRectangle(cornerRadius: 2).fill(.quaternary.opacity(0.5))
                RoundedRectangle(cornerRadius: 2)
                    .fill(color.opacity(dim ? 0.25 : 0.9))
                    .frame(height: max(2, barHeight * CGFloat(min(max(level, 0), 1))))
            }
            .frame(height: barHeight)
            Text(label)
                .font(.system(size: 9)).foregroundStyle(.secondary)
                .lineLimit(1).minimumScaleFactor(0.7)
        }
        .frame(maxWidth: .infinity)
    }
}

// MARK: - FocusBandCard

/// The tunable Focus Band editor (music's "LFO equivalent"): enable, a log-Hz
/// low/high range, gain, and a one-tap route. Writes go through
/// `AudioActions.setFocusBand` (which updates BOTH the mic analyzer and the
/// mirror); the displayed value reads the mirror's observable copy.
private struct FocusBandCard: View {
    let mirror: ParameterMirror
    let audio: AudioActions?
    /// Reuse MusicSection's route-add so the "Route" button dedupes like the
    /// quick-adds.
    let addRoute: (SignalID, ParamKey, Float, Float, MappingCurve, Int) -> Void

    private static let minHz: Float = 20
    private static let maxHz: Float = 20_000

    private var band: AudioFocusBand { mirror.focusBand }

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Spacing.xxs) {
            HStack {
                Text("Focus Band").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Text(rangeLabel).font(.caption2.monospacedDigit()).foregroundStyle(.tertiary)
                Toggle("", isOn: SwiftUI.Binding(
                    get: { band.enabled },
                    set: { v in update { $0.enabled = v } }))
                    .labelsHidden()
            }
            hzRow("Low", value: SwiftUI.Binding(
                get: { Self.hzToFrac(band.lowHz) },
                set: { f in update { $0.lowHz = Self.fracToHz(f) } }))
            hzRow("High", value: SwiftUI.Binding(
                get: { Self.hzToFrac(band.highHz) },
                set: { f in update { $0.highHz = Self.fracToHz(f) } }))
            HStack(spacing: DS.Spacing.xs) {
                Text("Gain").font(.caption2).foregroundStyle(.secondary)
                Slider(value: SwiftUI.Binding(
                    get: { Double(band.gain) },
                    set: { v in update { $0.gain = Float(v) } }), in: 0...4)
                Button {
                    addRoute(.audioBandUser, .cameraDolly, 1, 1.6, .exponential(k: 1.6), 0)
                } label: { Label("Route", systemImage: "plus.circle") }
                .buttonStyle(.borderless).font(.caption2)
                .disabled(!band.enabled)
            }
            Text("Pick a frequency window to react to — it publishes as a source (Focus Band) you can route anywhere.")
                .font(.caption2).foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .opacity(band.enabled ? 1 : 0.6)
    }

    private var rangeLabel: String {
        func fmt(_ hz: Float) -> String {
            hz >= 1000 ? String(format: "%.1fk", hz / 1000) : String(format: "%.0f", hz)
        }
        return "\(fmt(band.lowHz))–\(fmt(band.highHz)) Hz"
    }

    private func hzRow(_ title: String, value: SwiftUI.Binding<Double>) -> some View {
        HStack(spacing: DS.Spacing.xs) {
            Text(title).font(.caption2).foregroundStyle(.secondary)
                .frame(width: 34, alignment: .leading)
            Slider(value: value, in: 0...1)
        }
    }

    /// Mutate the band and push it to the analyzer + mirror.
    private func update(_ mutate: (inout AudioFocusBand) -> Void) {
        var b = mirror.focusBand
        mutate(&b)
        if b.lowHz > b.highHz { swap(&b.lowHz, &b.highHz) }
        if let set = audio?.setFocusBand { set(b) } else { mirror.setFocusBand(b) }
    }

    // Log-frequency mapping so the slider gives even resolution across octaves.
    private static func hzToFrac(_ hz: Float) -> Double {
        let clamped = min(max(hz, minHz), maxHz)
        return Double(log(clamped / minHz) / log(maxHz / minHz))
    }

    private static func fracToHz(_ frac: Double) -> Float {
        minHz * powf(maxHz / minHz, Float(min(max(frac, 0), 1)))
    }
}

// MARK: - MusicPreset

/// A named recipe: a bundle of audio→param routes that recreates a look from
/// the original app, mapped onto the rebuild's catalog params (the same
/// source/target conventions as `LegacyBindingMigration`). Pure + testable:
/// `bindings(layout:)` resolves against the live catalog, skipping targets the
/// catalog doesn't have and clamping outputs into each param's range.
public struct MusicPreset: Identifiable, Sendable {
    public let id: String
    public let name: String
    public let icon: String
    public let summary: String
    let routes: [Route]

    struct Route: Sendable {
        let signal: SignalID
        let key: ParamKey
        let outLo: Float
        let outHi: Float
        let curve: MappingCurve
        let policy: BindingPolicy
    }

    public func bindings(layout: CatalogLayout) -> [ThresholdCore.Binding] {
        routes.compactMap { r in
            guard let entry = layout.entry(for: r.key) else { return nil }
            return ThresholdCore.Binding(
                signal: r.signal, param: r.key, lane: .music,
                mapping: SignalMapping(
                    inputLo: 0, inputHi: 1,
                    outputLo: entry.spec.range.clamp(r.outLo),
                    outputHi: entry.spec.range.clamp(r.outHi),
                    curve: r.curve, deadzone: 0.02),
                policy: r.policy)
        }
    }

    /// The shipped recipes. Targets are `.replace`/`.multiplicative` catalog
    /// params (Catalog.swift): a momentary music route drives the param while
    /// sound is present and reverts to the scene value on silence.
    public static let builtIn: [MusicPreset] = [
        MusicPreset(
            id: "colours-melting", name: "Colours Melting", icon: "drop.fill",
            summary: "Level→Saturation, Treble→Color Offset, Mid→Brightness",
            routes: [
                Route(signal: .audioRMS, key: .colorSaturation,
                      outLo: 0.6, outHi: 1.8, curve: .smooth, policy: .momentary),
                Route(signal: .audioBandHigh, key: .colorGradientOffset,
                      outLo: 0, outHi: 1, curve: .smooth, policy: .momentary),
                Route(signal: .audioBandMid, key: .colorBrightness,
                      outLo: 0.7, outHi: 1.5, curve: .smooth, policy: .momentary),
            ]),
        MusicPreset(
            id: "beat-pulse", name: "Beat Pulse", icon: "bolt.fill",
            summary: "Onset→AO pulse, Bass→Dolly",
            routes: [
                Route(signal: .audioOnset, key: .engineAOStrength,
                      outLo: 0, outHi: 1.4, curve: .pulse(threshold: 0.4), policy: .momentary),
                Route(signal: .audioBandLow, key: .cameraDolly,
                      outLo: 1, outHi: 1.5, curve: .exponential(k: 1.6), policy: .momentary),
            ]),
        MusicPreset(
            id: "deep-drift", name: "Deep Drift", icon: "wind",
            summary: "Bass→Dolly, Level→Color Offset, Treble→Contrast",
            routes: [
                Route(signal: .audioBandLow, key: .cameraDolly,
                      outLo: 1, outHi: 1.7, curve: .smooth, policy: .momentary),
                Route(signal: .audioRMS, key: .colorGradientOffset,
                      outLo: 0, outHi: 0.6, curve: .smooth, policy: .momentary),
                Route(signal: .audioBandHigh, key: .colorContrast,
                      outLo: 0.8, outHi: 1.6, curve: .smooth, policy: .momentary),
            ]),
    ]
}

// MARK: - RoutesSection (Motion ▸ Routes)

/// The binding list: source → param, with mapping. The full modulation editor.
public struct RoutesSection: View {
    let mirror: ParameterMirror
    let layout: CatalogLayout

    /// Default ON: show only the active fractal's targets/routes. Off exposes
    /// every fractal's params for building cross-fractal preset sets (device-
    /// local UI state, not scene content).
    @AppStorage("threshold.ui.routes.filterCurrent") private var filterToCurrent = true

    public init(mirror: ParameterMirror, layout: CatalogLayout) {
        self.mirror = mirror
        self.layout = layout
    }

    private var allTargets: [BindTarget] {
        BindTarget.all(layout: layout, dynamic: mirror.dynamicEntries)
    }

    /// Targets offered in the picker, narrowed to the active fractal (+ the
    /// universal params) when the filter is on.
    private var visibleTargets: [BindTarget] {
        guard filterToCurrent else { return allTargets }
        return allTargets.filter { $0.fractalKey == nil || $0.fractalKey == mirror.deKey }
    }

    /// A route is shown when its target is universal or belongs to the active
    /// fractal — unless the filter is off, when all show.
    private func isVisible(_ route: ThresholdCore.Binding) -> Bool {
        guard filterToCurrent else { return true }
        let fk = BindTarget.fractalKey(for: route.param)
        return fk == nil || fk == mirror.deKey
    }

    private var visibleRoutes: [ThresholdCore.Binding] {
        mirror.bindings.filter(isVisible)
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: DS.Spacing.sm) {
            // The fractal filter sits ABOVE the card, not inside it.
            filterBar
            VStack(alignment: .leading, spacing: DS.Spacing.sm) {
                SectionHeader("Routes", icon: "point.topleft.down.to.point.bottomright.curvepath") {
                    Button {
                        addRoute()
                    } label: { Image(systemName: "plus.circle.fill") }
                    .buttonStyle(.borderless)
                }
                if mirror.bindings.isEmpty {
                    Text("No routes yet. Add one to drive any control from an audio band or an LFO.")
                        .font(.caption2).foregroundStyle(.tertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                ForEach(visibleRoutes) { route in
                    RouteCard(route: route, mirror: mirror, targets: visibleTargets)
                }
                let hidden = mirror.bindings.count - visibleRoutes.count
                if hidden > 0 {
                    Text("^[\(hidden) route](inflect: true) for other fractals hidden — "
                         + "switch to All fractals to see them.")
                        .font(.caption2).foregroundStyle(.tertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .moduleCard(.teal)
        }
    }

    /// The fractal filter, above the Routes card. "Current" = the active fractal
    /// (+ universal params); "All fractals" exposes every DE's params.
    private var filterBar: some View {
        Picker("Fractal type", selection: $filterToCurrent) {
            Text("Current").tag(true)
            Text("All fractals").tag(false)
        }
        .pickerStyle(.segmented)
        .font(.caption)
    }

    private func addRoute() {
        // Default the source to the first real LFO if one exists, else the bass
        // audio band — a LIVE signal. The old fallback to `standardLFOs.first`
        // pointed at an unconfigured LFO slot that drives nothing until the user
        // also creates that LFO, so a fresh route did visibly nothing.
        // Target: the first VISIBLE target so the route lands on the fractal
        // you're looking at.
        let source = mirror.lfos.first?.slot ?? .audioBandLow
        let target = visibleTargets.first ?? allTargets.first
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
                } label: { Image(systemName: "trash") }
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
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: DS.Radius.inset, style: .continuous))
        .background(Color.black.opacity(0.20), in: RoundedRectangle(cornerRadius: DS.Radius.inset, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: DS.Radius.inset, style: .continuous)
                .strokeBorder(Color.teal.opacity(0.20), lineWidth: 0.7))
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
            ForEach(BindTarget.grouped(targets, activeFractal: mirror.deKey), id: \.title) { section in
                Section(section.title) {
                    ForEach(section.targets) { t in
                        Button(t.label) {
                            var r = route; r.param = t.key; r.component = t.component
                            // Re-center output on the new target's range.
                            r.mapping.outputLo = t.range.lowerBound
                            r.mapping.outputHi = t.range.upperBound
                            mirror.updateBinding(r)
                        }
                    }
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
            HStack(spacing: 1) {
                EditableNumberText(
                    display: String(format: "%.2f", lo.wrappedValue),
                    value: Double(lo.wrappedValue),
                    range: Double(domain.lowerBound)...Double(domain.upperBound),
                    commit: { lo.wrappedValue = Float($0) },
                    font: .caption2.monospacedDigit(),
                    foreground: AnyShapeStyle(.tertiary),
                    width: nil, alignment: .trailing)
                Text("…").font(.caption2).foregroundStyle(.tertiary)
                EditableNumberText(
                    display: String(format: "%.2f", hi.wrappedValue),
                    value: Double(hi.wrappedValue),
                    range: Double(domain.lowerBound)...Double(domain.upperBound),
                    commit: { hi.wrappedValue = Float($0) },
                    font: .caption2.monospacedDigit(),
                    foreground: AnyShapeStyle(.tertiary),
                    width: nil, alignment: .leading)
            }
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
                } label: { Image(systemName: "plus.circle.fill") }
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
                } label: { Image(systemName: "trash") }
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
                } label: { Label("Add wave", systemImage: "plus.circle.fill") }
                .buttonStyle(.borderless).font(.caption2)
                Spacer()
                Text("Bias").font(.caption2).foregroundStyle(.secondary)
                Slider(value: SwiftUI.Binding(
                    get: { lfo.bias }, set: { v in update { $0.bias = v } }), in: -1...1)
                    .frame(maxWidth: 110)
            }
        }
        .padding(DS.Spacing.sm)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: DS.Radius.inset, style: .continuous))
        .background(Color.black.opacity(0.20), in: RoundedRectangle(cornerRadius: DS.Radius.inset, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: DS.Radius.inset, style: .continuous)
                .strokeBorder(Color.indigo.opacity(0.20), lineWidth: 0.7))
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
                    Image(systemName: "trash")
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
            HStack(spacing: 2) {
                Text(title)
                EditableNumberText(
                    display: String(format: "%.2f", value.wrappedValue),
                    value: Double(value.wrappedValue),
                    range: Double(range.lowerBound)...Double(range.upperBound),
                    commit: { value.wrappedValue = Float($0) },
                    font: .system(size: 9),
                    foreground: AnyShapeStyle(.tertiary),
                    width: nil,
                    alignment: .center)
                if !suffix.isEmpty { Text(suffix) }
            }
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
    /// Reference instant captured on first render. `LFOSpec.value` casts its
    /// time to `Float`; the absolute `timeIntervalSinceReferenceDate` (~8×10⁸ s)
    /// has a Float ULP of ~64 s, which annihilates the per-frame delta and
    /// freezes the plot. Sampling ELAPSED time (small, starts at 0) keeps Float
    /// precision so the wave animates — matching the near-zero content time the
    /// real LFOEngine feeds. (Cosmetic only; it deliberately does not pause
    /// with the session clock.)
    @State private var start = Date()

    var body: some View {
        TimelineView(.animation) { context in
            Canvas { ctx, size in
                let now = context.date.timeIntervalSince(start)
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
