import AVFoundation
import SwiftUI

@MainActor
public final class IncomingCallViewModel: ObservableObject {
    @Published var name = "Caller Name"
    @Published var role = "Role"
    @Published var status = "Incoming Call..."
    @Published var callDetail = "Secure audio call"
    @Published var imageURL: URL?
    public var onAccept: (() -> Void)?
    public var onDecline: (() -> Void)?

    public init(
        name: String = "Caller Name",
        role: String = "Role",
        status: String = "Incoming Call...",
        callDetail: String = "Secure audio call",
        imageURL: URL? = nil,
        onAccept: (() -> Void)? = nil,
        onDecline: (() -> Void)? = nil
    ) {
        self.name = name
        self.role = role
        self.status = status
        self.callDetail = callDetail
        self.imageURL = imageURL
        self.onAccept = onAccept
        self.onDecline = onDecline
    }

    public convenience init(
        session: CallSession,
        configuration: CallUIConfiguration,
        onAccept: (() -> Void)? = nil,
        onDecline: (() -> Void)? = nil
    ) {
        self.init(
            name: session.details?.name ?? session.payload.callerName,
            role: session.details?.roleDescription ?? session.payload.role.rawValue.capitalized,
            status: configuration.incomingText,
            onAccept: onAccept,
            onDecline: onDecline
        )
    }

    func update(session: CallSession, configuration: CallUIConfiguration) {
        name = session.details?.name ?? session.payload.callerName
        role = session.details?.roleDescription ?? session.payload.role.rawValue.capitalized
        status = configuration.incomingText
        imageURL = session.details?.imageURL
    }

    var displayTitle: String {
        name.isEmpty ? "Caller" : name
    }
}

public struct IncomingCallView: View {
    @ObservedObject var model: IncomingCallViewModel
    @Environment(\.colorScheme) private var colorScheme
    @State private var animatePulse = false

    public init(model: IncomingCallViewModel) {
        self.model = model
    }

    public var body: some View {
        GeometryReader { geometry in
            let metrics = IncomingCallLayoutMetrics(containerSize: geometry.size)
            let palette = IncomingCallPalette(colorScheme: colorScheme)

            ZStack {
                IncomingCallBackgroundView(animatePulse: animatePulse, palette: palette)
                    .ignoresSafeArea()

                ScrollView(.vertical, showsIndicators: false) {
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
            .onAppear {
                withAnimation(.easeInOut(duration: 2).repeatForever(autoreverses: true)) {
                    animatePulse = true
                }
            }
        }
    }

    @ViewBuilder
    private func heroSection(metrics: IncomingCallLayoutMetrics) -> some View {
        let palette = IncomingCallPalette(colorScheme: colorScheme)
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
            .padding(.top, metrics.prefersWideLayout ? 12 : 0)

            VStack(spacing: 10) {
                Text(model.displayTitle)
                    .font(.system(size: metrics.nameFontSize, weight: .bold, design: .rounded))
                    .foregroundStyle(palette.primaryText)
                    .multilineTextAlignment(.center)
                    .lineLimit(2)
                    .minimumScaleFactor(0.75)

                Text(model.role)
                    .font(metrics.prefersWideLayout ? .title3.weight(.medium) : .headline)
                    .foregroundStyle(palette.secondaryText)
                    .multilineTextAlignment(.center)
                    .lineLimit(2)

                Text(model.status)
                    .font(.system(size: metrics.statusFontSize, weight: .semibold, design: .rounded))
                    .foregroundStyle(palette.primaryText)
                    .multilineTextAlignment(.center)

                Label(model.callDetail, systemImage: "phone.fill.badge.plus")
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(palette.tertiaryText)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                    .background(
                        Capsule(style: .continuous)
                            .fill(palette.capsuleFill)
                    )
            }
        }
        .frame(maxWidth: .infinity)
    }

    @ViewBuilder
    private func controlsSection(metrics: IncomingCallLayoutMetrics) -> some View {
        let palette = IncomingCallPalette(colorScheme: colorScheme)
        HStack(spacing: metrics.controlSpacing) {
            IncomingCallIconControl(
                title: "Decline",
                imageResource: .declineCall,
                titleColor: palette.primaryText,
                action: { model.onDecline?() }
            )

            IncomingCallIconControl(
                title: "Accept",
                imageResource: .acceptCall,
                titleColor: palette.primaryText,
                action: { model.onAccept?() }
            )
        }
        .frame(maxWidth: metrics.controlsWidth)
        .frame(maxWidth: .infinity)
        .padding(.top, 12)
    }
}

private struct IncomingCallBackgroundView: View {
    let animatePulse: Bool
    let palette: IncomingCallPalette

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

private struct IncomingCallLayoutMetrics {
    let containerSize: CGSize

    var prefersWideLayout: Bool {
        containerSize.width >= 760 && containerSize.width > containerSize.height * 0.82
    }

    var maxContentWidth: CGFloat {
        min(max(containerSize.width - 48, 0), prefersWideLayout ? 960 : 620)
    }

    var controlsWidth: CGFloat {
        prefersWideLayout ? 420 : min(maxContentWidth, 320)
    }

    var horizontalPadding: CGFloat {
        prefersWideLayout ? 40 : 24
    }

    var verticalPadding: CGFloat {
        prefersWideLayout ? 32 : 24
    }

    var avatarSize: CGFloat {
        prefersWideLayout ? 164 : min(max(containerSize.width * 0.24, 104), 150)
    }

    var nameFontSize: CGFloat {
        prefersWideLayout ? 44 : min(max(containerSize.width * 0.082, 30), 40)
    }

    var statusFontSize: CGFloat {
        prefersWideLayout ? 28 : 22
    }

    var sectionSpacing: CGFloat {
        prefersWideLayout ? 40 : 30
    }

    var heroSpacing: CGFloat {
        prefersWideLayout ? 22 : 18
    }

    var controlSpacing: CGFloat {
        prefersWideLayout ? 80 : 48
    }
}

private struct IncomingCallIconControl: View {
    let title: String
    let imageResource: ImageResource
    let titleColor: Color
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 10) {
                Image(imageResource)
                    .renderingMode(.original)
                Text(title)
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(titleColor)
            }
            .frame(maxWidth: .infinity)
        }
        .buttonStyle(IncomingCallIconControlButtonStyle())
    }
}

private struct IncomingCallPalette {
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

    var capsuleFill: Color {
        colorScheme == .dark ? Color.white.opacity(0.09) : Color.white.opacity(0.58)
    }
}

private struct IncomingCallIconControlButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .animation(.spring(response: 0.25, dampingFraction: 0.8), value: configuration.isPressed)
    }
}

@available(iOS 17.0, *)
#Preview("Incoming Call") {
    IncomingCallView(model: incomingCallPreviewModel)
}

@available(iOS 17.0, *)
#Preview("iPad Landscape", traits: .fixedLayout(width: 1024, height: 768)) {
    IncomingCallView(model: incomingCallIPadPreviewModel)
}

@MainActor
private var incomingCallPreviewModel: IncomingCallViewModel {
    let model = IncomingCallViewModel()
    model.name = "Avery Stone"
    model.role = "Support Specialist"
    model.status = "Incoming Call..."
    return model
}

@MainActor
private var incomingCallIPadPreviewModel: IncomingCallViewModel {
    let model = IncomingCallViewModel()
    model.name = "Morgan Patel"
    model.role = "Dispatch Coordinator"
    model.status = "Incoming Call..."
    model.callDetail = "Secure audio call"
    return model
}
