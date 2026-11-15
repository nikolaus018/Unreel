import SwiftUI

struct OnboardingView: View {
    let done: () -> Void
    @State private var appeared = false

    private let features: [(icon: String, color: Color, title: String, text: String)] = [
        ("shield.lefthalf.filled", .red, "No ads", "Video ads, banners and promoted results are removed, with filter lists from uBlock Origin."),
        ("rectangle.slash", .pink, "No Shorts", "Shorts shelves disappear, and Shorts links open as regular videos."),
        ("forward.end.alt", .green, "Skip the sponsor reads", "SponsorBlock skips sponsored segments and \"like and subscribe\" reminders."),
        ("headphones", .indigo, "Keeps playing", "Background playback, Picture in Picture and lock screen controls."),
    ]

    var body: some View {
        VStack(spacing: 0) {
            Spacer(minLength: 24)
            Image("Logo")
                .resizable()
                .frame(width: 92, height: 92)
                .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
                .shadow(color: .red.opacity(0.35), radius: 18, y: 8)
                .scaleEffect(appeared ? 1 : 0.7)
                .opacity(appeared ? 1 : 0)
            Text("Welcome to Unreel")
                .font(.largeTitle.weight(.bold))
                .multilineTextAlignment(.center)
                .padding(.top, 22)
            Text("YouTube, without the noise.")
                .font(.title3)
                .foregroundStyle(.secondary)
                .padding(.top, 4)

            VStack(alignment: .leading, spacing: 22) {
                ForEach(Array(features.enumerated()), id: \.offset) { index, f in
                    HStack(alignment: .top, spacing: 16) {
                        Image(systemName: f.icon)
                            .font(.system(size: 22, weight: .semibold))
                            .foregroundStyle(f.color)
                            .frame(width: 36)
                        VStack(alignment: .leading, spacing: 3) {
                            Text(f.title).font(.headline)
                            Text(f.text).font(.subheadline).foregroundStyle(.secondary)
                        }
                    }
                    .opacity(appeared ? 1 : 0)
                    .offset(y: appeared ? 0 : 14)
                    .animation(.spring(duration: 0.5).delay(0.15 + Double(index) * 0.07), value: appeared)
                }
            }
            .padding(.horizontal, 32)
            .padding(.top, 40)

            Spacer(minLength: 24)

            Button(action: done) {
                Text("Get Started")
                    .font(.headline)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 6)
            }
            .buttonStyle(.glassProminent)
            .controlSize(.large)
            .padding(.horizontal, 32)

            Text("You can change all of this later in the Settings tab.")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .padding(.top, 12)
                .padding(.bottom, 20)
        }
        .frame(maxWidth: 560)
        .onAppear { withAnimation(.spring(duration: 0.6)) { appeared = true } }
    }
}
