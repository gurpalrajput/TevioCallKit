import SwiftUI

struct CallAvatarView: View {
    let imageURL: URL?
    let size: CGFloat
    let strokeColor: Color

    var body: some View {
        Group {
            if let imageURL {
                AsyncImage(url: imageURL) { phase in
                    switch phase {
                    case .success(let image):
                        image
                            .resizable()
                            .scaledToFill()
                    default:
                        placeholder
                    }
                }
            } else {
                placeholder
            }
        }
        .frame(width: size, height: size)
        .clipShape(Circle())
        .overlay(
            Circle()
                .stroke(strokeColor, lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.24), radius: 24, y: 12)
    }

    private var placeholder: some View {
        Image(.profilePlaceHolder)
            .resizable()
            .scaledToFill()
    }
}
