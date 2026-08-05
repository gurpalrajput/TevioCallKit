import AudioToolbox
import SwiftUI
import UIKit

@MainActor
public final class ActiveCallViewModel: ObservableObject {
    @Published var name = "Caller Name"
    @Published var role = "Role"
    @Published var status = "Connecting..."
    @Published var remoteMuteText = ""
    @Published var isMuted = false
    @Published var speakerEnabled = false
    @Published var callDetail = "Secure audio call"
    @Published var isConnecting = true
    @Published var imageURL: URL?
    public var onToggleMute: (() -> Void)?
    public var onToggleSpeaker: (() -> Void)?
    public var onEnd: (() -> Void)?

    public init(
        name: String = "Caller Name",
        role: String = "Role",
        status: String = "Connecting...",
        remoteMuteText: String = "",
        isMuted: Bool = false,
        speakerEnabled: Bool = false,
        callDetail: String = "Secure audio call",
        isConnecting: Bool = true,
        imageURL: URL? = nil,
        onToggleMute: (() -> Void)? = nil,
        onToggleSpeaker: (() -> Void)? = nil,
        onEnd: (() -> Void)? = nil
    ) {
        self.name = name
        self.role = role
        self.status = status
        self.remoteMuteText = remoteMuteText
        self.isMuted = isMuted
        self.speakerEnabled = speakerEnabled
        self.callDetail = callDetail
        self.isConnecting = isConnecting
        self.imageURL = imageURL
        self.onToggleMute = onToggleMute
        self.onToggleSpeaker = onToggleSpeaker
        self.onEnd = onEnd
    }

    public convenience init(
        session: CallSession,
        configuration: CallUIConfiguration,
        onToggleMute: (() -> Void)? = nil,
        onToggleSpeaker: (() -> Void)? = nil,
        onEnd: (() -> Void)? = nil
    ) {
        self.init(
            name: session.details?.name ?? session.payload.callerName,
            role: session.details?.roleDescription ?? session.payload.role.rawValue.capitalized,
            status: configuration.connectingText,
            onToggleMute: onToggleMute,
            onToggleSpeaker: onToggleSpeaker,
            onEnd: onEnd
        )
    }

    public var muteTitle: String {
        isMuted ? "Unmute" : "Mute"
    }

    public var speakerTitle: String {
        speakerEnabled ? "Speaker Off" : "Speaker"
    }

    func update(session: CallSession) {
        name = session.details?.name ?? session.payload.callerName
        role = session.details?.roleDescription ?? session.payload.role.rawValue.capitalized
        isConnecting = session.state != .active
        imageURL = session.details?.imageURL
    }

    func updateStatus(_ text: String) {
        status = text
        isConnecting = !text.contains(":")
    }

    func updateDuration(seconds: Int) {
        let minutes = seconds / 60
        let remainingSeconds = seconds % 60
        status = String(format: "%d:%02d", minutes, remainingSeconds)
        isConnecting = false
    }

    func updateRemoteMuted(_ isMuted: Bool) {
        remoteMuteText = isMuted ? "Remote muted" : ""
    }

    var remoteMuteVisible: Bool {
        !remoteMuteText.isEmpty
    }

    var displayTitle: String {
        name.isEmpty ? "Caller" : name
    }

    var detailText: String {
        remoteMuteVisible ? remoteMuteText : callDetail
    }
}

public struct ActiveCallView: View {
    @ObservedObject var model: ActiveCallViewModel
    @Environment(\.colorScheme) private var colorScheme
    @State private var animatePulse = false

    public init(model: ActiveCallViewModel) {
        self.model = model
    }

    public var body: some View {
        GeometryReader { geometry in
            let metrics = ActiveCallLayoutMetrics(containerSize: geometry.size)
            let palette = ActiveCallPalette(colorScheme: colorScheme)

            ZStack {
                ActiveCallBackgroundView(animatePulse: animatePulse, palette: palette)
                    .ignoresSafeArea()

                ScrollView(.vertical, showsIndicators: false) {
                    if metrics.prefersSideBySideLayout {
                        HStack(spacing: metrics.sectionSpacing) {
                            heroSection(metrics: metrics)
                            controlsSection(metrics: metrics)
                        }
                        .frame(maxWidth: metrics.maxContentWidth, alignment: .center)
                        .frame(maxWidth: .infinity)
                        .padding(.horizontal, metrics.horizontalPadding)
                        .padding(.vertical, metrics.verticalPadding)
                    } else {
                        VStack(spacing: metrics.sectionSpacing) {
                            heroSection(metrics: metrics)
                            controlsSection(metrics: metrics)
                        }
                        .frame(maxWidth: metrics.maxContentWidth)
                        .frame(maxWidth: .infinity)
                        .padding(.horizontal, metrics.horizontalPadding)
                        .padding(.vertical, metrics.verticalPadding)
                    }
                }
            }
            .onAppear {
                withAnimation(.easeInOut(duration: 2).repeatForever(autoreverses: true)) {
                    animatePulse = true
                }
            }
        }
    }

    @ViewBuilder
    private func heroSection(metrics: ActiveCallLayoutMetrics) -> some View {
        let palette = ActiveCallPalette(colorScheme: colorScheme)
        VStack(spacing: metrics.heroSpacing) {
            ZStack {
                Circle()
                    .fill(palette.haloFill)
                    .frame(width: metrics.avatarSize + 54, height: metrics.avatarSize + 54)
                    .scaleEffect(animatePulse ? 1.06 : 0.94)
                    .blur(radius: 1)

                Circle()
                    .stroke(palette.haloStroke, lineWidth: 1)
                    .frame(width: metrics.avatarSize + 24, height: metrics.avatarSize + 24)
                    .scaleEffect(animatePulse ? 1.03 : 0.97)

                CallAvatarView(
                    imageURL: model.imageURL,
                    size: metrics.avatarSize,
                    strokeColor: palette.avatarStroke
                )
            }
            .padding(.top, metrics.prefersSideBySideLayout ? 12 : 0)

            VStack(spacing: 10) {
                Text(model.displayTitle)
                    .font(.system(size: metrics.nameFontSize, weight: .bold, design: .rounded))
                    .foregroundStyle(palette.primaryText)
                    .multilineTextAlignment(.center)
                    .lineLimit(2)
                    .minimumScaleFactor(0.75)

                Text(model.role)
                    .font(metrics.prefersSideBySideLayout ? .title3.weight(.medium) : .headline)
                    .foregroundStyle(palette.secondaryText)
                    .multilineTextAlignment(.center)
                    .lineLimit(2)

                Text(model.status)
                    .font(.system(size: metrics.statusFontSize, weight: .semibold, design: .rounded))
                    .foregroundStyle(palette.primaryText)
                    .monospacedDigit()

                Label(model.detailText, systemImage: model.remoteMuteVisible ? "mic.slash.fill" : "lock.fill")
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(model.remoteMuteVisible ? palette.warningText : palette.tertiaryText)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                    .background(
                        Capsule(style: .continuous)
                            .fill(model.remoteMuteVisible ? palette.warningFill : palette.capsuleFill)
                    )
                    .animation(.spring(response: 0.28, dampingFraction: 0.82), value: model.remoteMuteVisible)
            }
        }
        .frame(maxWidth: .infinity)
    }

    @ViewBuilder
    private func controlsSection(metrics: ActiveCallLayoutMetrics) -> some View {
        let palette = ActiveCallPalette(colorScheme: colorScheme)
        VStack(spacing: 28) {
            HStack(spacing: 24) {
                ActiveCallIconControl(
                    title: model.muteTitle,
                    imageResource: model.isMuted ? .unMute : .mute,
                    titleColor: palette.primaryText,
                    action: {
                        model.onToggleMute?()
                    }
                )

                ActiveCallIconControl(
                    title: model.speakerTitle,
                    imageResource: model.speakerEnabled ? .speakerEnabled : .speakerOff,
                    titleColor: palette.primaryText,
                    action: {
                        model.onToggleSpeaker?()
                    }
                )
            }
            .frame(maxWidth: metrics.controlsWidth)

            Button(action: { model.onEnd?() }) {
                VStack(spacing: 10) {
                    Image(.declineCall)
                    Text("End Call")
                        .font(.subheadline.weight(.medium))
                }
                .foregroundStyle(palette.primaryText)
            }
        }
        .frame(maxWidth: .infinity)
    }
}

private struct ActiveCallBackgroundView: View {
    let animatePulse: Bool
    let palette: ActiveCallPalette

    var body: some View {
        ZStack {
            LinearGradient(
                colors: palette.backgroundGradient,
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )

            Circle()
                .fill(palette.topGlow)
                .frame(width: 320, height: 320)
                .blur(radius: 24)
                .offset(x: animatePulse ? -90 : -40, y: -260)

            Circle()
                .fill(palette.bottomGlow)
                .frame(width: 280, height: 280)
                .blur(radius: 28)
                .offset(x: animatePulse ? 120 : 80, y: 260)
        }
    }
}

private struct ActiveCallLayoutMetrics {
    let containerSize: CGSize

    var prefersSideBySideLayout: Bool {
        containerSize.width >= 760 && containerSize.width > containerSize.height * 0.82
    }

    var maxContentWidth: CGFloat {
        min(max(containerSize.width - 48, 0), prefersSideBySideLayout ? 980 : 620)
    }

    var controlsWidth: CGFloat {
        prefersSideBySideLayout ? 360 : maxContentWidth
    }

    var horizontalPadding: CGFloat {
        prefersSideBySideLayout ? 40 : 24
    }

    var verticalPadding: CGFloat {
        prefersSideBySideLayout ? 32 : 24
    }

    var avatarSize: CGFloat {
        prefersSideBySideLayout ? 164 : min(max(containerSize.width * 0.24, 104), 150)
    }

    var nameFontSize: CGFloat {
        prefersSideBySideLayout ? 44 : min(max(containerSize.width * 0.082, 30), 40)
    }

    var statusFontSize: CGFloat {
        prefersSideBySideLayout ? 28 : 22
    }

    var sectionSpacing: CGFloat {
        prefersSideBySideLayout ? 36 : 28
    }

    var heroSpacing: CGFloat {
        prefersSideBySideLayout ? 22 : 18
    }

    var endButtonHeight: CGFloat {
        prefersSideBySideLayout ? 68 : 62
    }
}

private struct ActiveCallIconControl: View {
    let title: String
    let imageResource: ImageResource
    let titleColor: Color
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 12) {
                Image(imageResource)
                    .renderingMode(.original)
                Text(title)
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(titleColor)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity)
        }
        .buttonStyle(ActiveCallIconControlButtonStyle())
    }
}

private struct ActiveCallPalette {
    let colorScheme: ColorScheme

    var backgroundGradient: [Color] {
        if colorScheme == .dark {
            return [
                Color(red: 0.07, green: 0.10, blue: 0.18),
                Color(red: 0.11, green: 0.18, blue: 0.29),
                Color(red: 0.17, green: 0.22, blue: 0.31)
            ]
        }
        return [
            Color(red: 0.95, green: 0.97, blue: 1.0),
            Color(red: 0.88, green: 0.93, blue: 0.99),
            Color(red: 0.82, green: 0.89, blue: 0.98)
        ]
    }

    var topGlow: Color {
        colorScheme == .dark ? Color.cyan.opacity(0.14) : Color.blue.opacity(0.16)
    }

    var bottomGlow: Color {
        colorScheme == .dark ? Color.blue.opacity(0.14) : Color.cyan.opacity(0.16)
    }

    var haloFill: Color {
        colorScheme == .dark ? Color.white.opacity(0.06) : Color.white.opacity(0.34)
    }

    var haloStroke: Color {
        colorScheme == .dark ? Color.white.opacity(0.16) : Color.blue.opacity(0.12)
    }

    var avatarStroke: Color {
        colorScheme == .dark ? Color.white.opacity(0.24) : Color.white.opacity(0.72)
    }

    var primaryText: Color {
        colorScheme == .dark ? .white : Color(red: 0.10, green: 0.14, blue: 0.22)
    }

    var secondaryText: Color {
        colorScheme == .dark ? .white.opacity(0.68) : Color(red: 0.21, green: 0.29, blue: 0.42).opacity(0.82)
    }

    var tertiaryText: Color {
        colorScheme == .dark ? .white.opacity(0.76) : Color(red: 0.18, green: 0.27, blue: 0.39).opacity(0.78)
    }

    var warningText: Color {
        colorScheme == .dark ? Color(red: 1.0, green: 0.86, blue: 0.55) : Color(red: 0.65, green: 0.41, blue: 0.05)
    }

    var capsuleFill: Color {
        colorScheme == .dark ? Color.white.opacity(0.09) : Color.white.opacity(0.58)
    }

    var warningFill: Color {
        colorScheme == .dark ? Color.white.opacity(0.16) : Color.orange.opacity(0.14)
    }
}

private struct ActiveCallIconControlButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .animation(.spring(response: 0.25, dampingFraction: 0.8), value: configuration.isPressed)
    }
}



struct ActiveCallView_Previews: PreviewProvider {
    static var previews: some View {
        Group {
            ActiveCallView(model: connectedPreviewModel)
                .previewDisplayName("Active Call")
            ActiveCallView(model: mutedPreviewModel)
                .previewDisplayName("Remote Muted")
            ActiveCallView(model: ipadPreviewModel)
                .previewLayout(.fixed(width: 1024, height: 768))
                .previewDisplayName("iPad Landscape")
        }
    }

    @MainActor
    private static var connectedPreviewModel: ActiveCallViewModel {
        let model = ActiveCallViewModel()
        model.name = "Avery Stone"
        model.role = "Support Specialist"
        model.status = "03:42"
        model.isConnecting = false
        return model
    }

    @MainActor
    private static var mutedPreviewModel: ActiveCallViewModel {
        let model = ActiveCallViewModel()
        model.name = "Jordan Mills"
        model.role = "Clinical Advisor"
        model.status = "Connecting..."
        model.remoteMuteText = "Remote muted"
        model.isMuted = true
        model.speakerEnabled = true
        return model
    }

    @MainActor
    private static var ipadPreviewModel: ActiveCallViewModel {
        let model = ActiveCallViewModel()
        model.name = "Morgan Patel"
        model.role = "Dispatch Coordinator"
        model.status = "12:08"
        model.isConnecting = false
        model.speakerEnabled = true
        model.callDetail = "End-to-end encrypted voice call"
        return model
    }
}
