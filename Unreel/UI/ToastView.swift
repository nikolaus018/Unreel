import SwiftUI

struct ToastView: View {
    let toast: Toast
    let dismiss: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: toast.icon)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(Color.accentColor)
            Text(toast.text)
                .font(.subheadline.weight(.medium))
                .lineLimit(2)
            if let title = toast.actionTitle, let action = toast.action {
                Divider().frame(height: 18)
                Button(title) {
                    action()
                    dismiss()
                }
                .font(.subheadline.weight(.semibold))
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 11)
        .background(.regularMaterial, in: Capsule())
        .overlay(Capsule().strokeBorder(.primary.opacity(0.08)))
        .shadow(color: .black.opacity(0.18), radius: 14, y: 6)
        .padding(.horizontal, 20)
        .onTapGesture(perform: dismiss)
        .gesture(DragGesture(minimumDistance: 10).onEnded { if $0.translation.height > 10 { dismiss() } })
    }
}
