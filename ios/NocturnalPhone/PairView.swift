import SwiftUI

/// Until this phone has a key. Full screen green, like the computer when it keeps working.
/// First the welcome: the mark, the name, one line, and two ways on (the demo, or pairing). Then pairing: the mark
/// moves up, the camera opens right on the page and reads the code Nocturnal shows on the computer; the code can also
/// be pasted or typed. The two buttons always sit in the same two places at the bottom.
struct PairView: View {
    @Environment(Computer.self) private var computer
    @State private var step = Step.welcome
    @State private var typing = false
    @State private var code = ""
    @State private var error: String?
    @FocusState private var fieldFocused: Bool
    @Namespace private var ns

    enum Step { case welcome, pair }

    var body: some View {
        GeometryReader { geo in
            VStack(spacing: 0) {
                head
                    .frame(height: Theme.head)
                    .padding(.top, 2)
                if step == .welcome { welcome } else { pair(geo.size) }
                bottom
                    .padding(.bottom, Theme.bottom - 14)
            }
            .padding(.horizontal, Theme.side)
        }
        .foregroundStyle(.white)
        .animation(Theme.grow, value: step)
        .animation(Theme.chrome, value: typing)
        .sensoryFeedback(.error, trigger: error) { _, new in new != nil }
    }

    // MARK: Head

    private var head: some View {
        HStack {
            if step == .pair {
                HeadCircle(symbol: "chevron.left", label: "Back") {
                    typing = false
                    fieldFocused = false
                    error = nil
                    step = .welcome
                }
                .transition(.offset(x: -24).combined(with: .scale(scale: 0.8)))
                .accessibilityIdentifier("back")
            }
            Spacer()
        }
    }

    // MARK: Welcome

    private var welcome: some View {
        VStack(spacing: 0) {
            Spacer()
            mark(size: 120)
                .rise(0)
            Text("Nocturnal")
                .font(.system(.largeTitle, weight: .bold))
                .matchedGeometryEffect(id: "name", in: ns)
                .padding(.top, 24)
                .rise(1)
            Text("Keeps your computer working with the lid shut while your agents work. See it and steer it from here.")
                .font(.body)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 320)
                .padding(.top, 10)
                .rise(2)
            Spacer()
            Spacer()
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: Pair

    private func pair(_ size: CGSize) -> some View {
        let side = min(size.width - Theme.side * 2 - 24, size.height * 0.42)
        return VStack(spacing: 0) {
            HStack(spacing: 12) {
                mark(size: 44)
                Text("Nocturnal")
                    .font(.system(.title2, weight: .bold))
                    .matchedGeometryEffect(id: "name", in: ns)
            }
            .padding(.top, 8)
            Spacer(minLength: 12)
            CameraFinder(found: pairFrom)
                .frame(width: side, height: side)
                .clipShape(.rect(cornerRadius: 40, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 40, style: .continuous)
                        .strokeBorder(.white.opacity(0.35), lineWidth: 1)
                }
                .transition(.scale(scale: 0.9).combined(with: .offset(y: 30)))
                .rise(0)
            Text("On your computer, open Nocturnal and choose Pair a Phone. Point the camera at the code.")
                .font(.body)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 330)
                .padding(.top, 22)
                .rise(1)
            Text(error ?? " ")
                .font(.headline)
                .foregroundStyle(Theme.red)
                .multilineTextAlignment(.center)
                .lineLimit(2, reservesSpace: true)
                .padding(.top, 10)
                .accessibilityIdentifier("pairError")
            Spacer(minLength: 12)
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: Bottom

    private var bottom: some View {
        GlassEffectContainer(spacing: 4) {
            HStack(spacing: Theme.gap) {
                switch step {
                case .welcome:
                    Button { computer.startDemo() } label: {
                        Text("Try the Demo").font(.headline).frame(maxWidth: .infinity, minHeight: Theme.band).contentShape(.capsule)
                    }
                    .buttonStyle(Press(scale: 0.97))
                    .glassEffect(.clear.interactive(), in: .capsule)
                    .glassEffectID("left", in: ns)
                    .accessibilityIdentifier("demo")
                    circle("arrow.right", "Pair a computer", id: "right", prominent: true) { step = .pair }
                        .accessibilityIdentifier("next")
                case .pair where typing:
                    TextField("Pairing code", text: $code)
                        .font(.body.monospaced())
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .submitLabel(.go)
                        .focused($fieldFocused)
                        .onSubmit(pairFromField)
                        .padding(.horizontal, 20)
                        .frame(maxWidth: .infinity, minHeight: Theme.band)
                        .glassEffect(.clear.interactive(), in: .capsule)
                        .glassEffectID("left", in: ns)
                        .accessibilityIdentifier("codeField")
                    circle("arrow.up", "Pair", id: "right", prominent: !code.isEmpty, action: pairFromField)
                        .disabled(code.isEmpty)
                        .accessibilityIdentifier("submit")
                case .pair:
                    Button {
                        guard let text = UIPasteboard.general.string, !text.isEmpty else {
                            withAnimation(Theme.chrome) { error = "Copy the code on your computer first, then paste." }
                            return
                        }
                        pairFrom(text)
                    } label: {
                        Label("Paste Code", systemImage: "doc.on.clipboard")
                            .font(.headline)
                            .frame(maxWidth: .infinity, minHeight: Theme.band)
                            .contentShape(.capsule)
                    }
                    .buttonStyle(Press(scale: 0.97))
                    .glassEffect(.clear.interactive(), in: .capsule)
                    .glassEffectID("left", in: ns)
                    .accessibilityIdentifier("paste")
                    circle("keyboard", "Type the code", id: "right", prominent: false) {
                        typing = true
                        fieldFocused = true
                    }
                    .accessibilityIdentifier("type")
                }
            }
        }
    }

    private func circle(_ symbol: String, _ label: String, id: String, prominent: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 20, weight: .bold))
                .foregroundStyle(prominent ? Theme.deep : .white)
                .contentTransition(.symbolEffect(.replace))
                .frame(width: Theme.band, height: Theme.band)
                .contentShape(.circle)
        }
        .buttonStyle(Press())
        .glassEffect(prominent ? .clear.tint(.white).interactive() : .clear.interactive(), in: .circle)
        .glassEffectID(id, in: ns)
        .accessibilityLabel(label)
    }

    private func mark(size: CGFloat) -> some View {
        Image("AppMark")
            .resizable()
            .interpolation(.high)
            .frame(width: size, height: size)
            .matchedGeometryEffect(id: "mark", in: ns)
            .accessibilityHidden(true)
    }

    // MARK: Pairing

    private func pairFromField() { pairFrom(code) }

    private func pairFrom(_ text: String) {
        guard let p = Pairing(text: text.trimmingCharacters(in: .whitespacesAndNewlines)) else {
            withAnimation(Theme.chrome) { error = "That isn't a Nocturnal pairing code." }
            return
        }
        error = nil
        fieldFocused = false
        computer.pair(p)
    }
}

#Preview {
    PairView().environment(Computer()).background(Ground(awake: 1))
}
