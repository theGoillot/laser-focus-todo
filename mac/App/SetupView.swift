import SwiftUI

/// First run: where the backend lives and the Mac token. Saved to the Keychain.
struct SetupView: View {
    @ObservedObject var model: AppModel
    @State private var url = ""
    @State private var token = ""
    @State private var error: String?
    @State private var busy = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 12) {
                Image("LaserFocusIcon").resizable().frame(width: 52, height: 52)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Laser Focus").font(.system(size: 22, weight: .bold))
                    Text("Connect your list").font(.system(size: 13, weight: .medium)).foregroundStyle(.secondary)
                }
            }
            Text("Your to-dos live on your own backend so \(model.agentName) can add to them while this Mac sleeps.")
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            VStack(alignment: .leading, spacing: 6) {
                Text("Backend URL").font(.system(size: 11, weight: .medium)).foregroundStyle(.secondary)
                TextField("https://your-backend.workers.dev", text: $url).textFieldStyle(.roundedBorder)
                Text("Mac token").font(.system(size: 11, weight: .medium)).foregroundStyle(.secondary).padding(.top, 4)
                SecureField("MAC_TOKEN", text: $token).textFieldStyle(.roundedBorder).onSubmit(connect)
            }
            if let error {
                Text(error).font(.system(size: 12)).foregroundStyle(.red)
            }
            HStack {
                Spacer()
                Button(action: connect) {
                    if busy { ProgressView().controlSize(.small) } else { Text("Connect") }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(url.isEmpty || token.isEmpty || busy)
            }
        }
        .padding(22)
        .frame(maxHeight: .infinity, alignment: .top)
    }

    private func connect() {
        guard !url.isEmpty, !token.isEmpty else { return }
        busy = true
        error = nil
        Task {
            error = await model.saveConnection(url: url, token: token)
            busy = false
        }
    }
}
