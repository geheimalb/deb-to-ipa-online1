import SwiftUI

// MARK: - Liquid Glass
// Ab iOS 26 echtes Liquid Glass, darunter (iOS 17 bis 25) ein weiches Glas-Material.

#if compiler(>=6.2)
@available(iOS 26.0, *)
private func makeGlass(tint: Color?, interactive: Bool) -> Glass {
    var g = Glass.regular
    if let tint { g = g.tint(tint) }
    if interactive { g = g.interactive() }
    return g
}
#endif

extension View {
    @ViewBuilder
    func liquidGlass<S: Shape>(in shape: S, tint: Color? = nil, interactive: Bool = false) -> some View {
        #if compiler(>=6.2)
        if #available(iOS 26.0, *) {
            self.glassEffect(makeGlass(tint: tint, interactive: interactive), in: shape)
        } else {
            self.legacyGlass(in: shape, tint: tint)
        }
        #else
        self.legacyGlass(in: shape, tint: tint)
        #endif
    }

    private func legacyGlass<S: Shape>(in shape: S, tint: Color?) -> some View {
        self
            .background(.ultraThinMaterial, in: shape)
            .background(shape.fill(tint ?? Color.clear))
            .overlay(shape.stroke(Color.white.opacity(0.18), lineWidth: 0.5))
    }

    @ViewBuilder
    func glassButton(prominent: Bool = false, tint: Color? = nil) -> some View {
        #if compiler(>=6.2)
        if #available(iOS 26.0, *) {
            if prominent {
                self.buttonStyle(.glassProminent).tint(tint)
            } else {
                self.buttonStyle(.glass).tint(tint)
            }
        } else {
            if prominent {
                self.buttonStyle(.borderedProminent).tint(tint)
            } else {
                self.buttonStyle(.bordered).tint(tint)
            }
        }
        #else
        if prominent {
            self.buttonStyle(.borderedProminent).tint(tint)
        } else {
            self.buttonStyle(.bordered).tint(tint)
        }
        #endif
    }
}

/// Gruppiert Glas-Elemente, damit sie unter iOS 26 weich ineinander übergehen.
struct GlassGroup<Content: View>: View {
    let spacing: CGFloat
    @ViewBuilder var content: () -> Content

    var body: some View {
        #if compiler(>=6.2)
        if #available(iOS 26.0, *) {
            GlassEffectContainer(spacing: spacing) { content() }
        } else {
            content()
        }
        #else
        content()
        #endif
    }
}

/// Runder Glas-Knopf mit Symbol
struct GlassIconButton: View {
    let systemName: String
    var tint: Color? = nil
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(.primary)
                .frame(width: 50, height: 50)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .liquidGlass(in: Circle(), tint: tint, interactive: true)
    }
}

/// Tempo-Schild: zeigt das Limit der aktuellen Straße (grau mit "–", wenn unbekannt)
struct SpeedSign: View {
    let limit: Int?
    var size: CGFloat = 48

    var body: some View {
        ZStack {
            Circle().fill(Color.white)
            Circle().strokeBorder(limit == nil ? Color.gray : Color.red, lineWidth: size * 0.1)
            Text(limit.map { String($0) } ?? "–")
                .font(.system(size: size * ((limit ?? 0) >= 100 ? 0.31 : 0.4), weight: .bold, design: .rounded))
                .foregroundStyle(Color.black)
        }
        .frame(width: size, height: size)
    }
}

/// Tempo-Anzeige wie bei Waze: weiß, wird rot, wenn du schneller fährst als erlaubt (ohne Ton)
struct SpeedGauge: View {
    let speed: Int?
    let tooFast: Bool

    var body: some View {
        VStack(spacing: -2) {
            Text(speed.map { String($0) } ?? "–")
                .font(.system(size: 30, weight: .bold, design: .rounded))
                .monospacedDigit()
            Text("km/h")
                .font(.system(size: 11, weight: .semibold))
        }
        .foregroundStyle(tooFast ? Color.white : Color.black)
        .frame(width: 70, height: 70)
        .background(Circle().fill(tooFast ? Color.red : Color.white))
        .overlay(Circle().strokeBorder(Color.black.opacity(0.08), lineWidth: 1))
        .shadow(color: .black.opacity(0.25), radius: 8, y: 3)
        .animation(.easeInOut(duration: 0.25), value: tooFast)
    }
}

// MARK: - Formatierung

func formatDistance(_ meters: Double) -> String {
    if meters < 1000 { return "\(Int((meters / 10).rounded()) * 10) m" }
    return (meters / 1000).formatted(.number.precision(.fractionLength(1))) + " km"
}
