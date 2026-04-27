import SwiftUI

/// Warning icon that appears when quarantined entries exist.
/// Shows a count badge and opens the review sheet when tapped.
struct QuarantineWarningIcon: View {
    let count: Int
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            ZStack(alignment: .topTrailing) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 48, height: 48)
                    .background(Color(white: 0.18))
                    .clipShape(Circle())

                if count > 0 {
                    Text("\(count)")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(.white)
                        .frame(width: 16, height: 16)
                        .background(Color.orange)
                        .clipShape(Circle())
                        .offset(x: 5, y: -5)
                }
            }
        }
        .buttonStyle(.plain)
    }
}
