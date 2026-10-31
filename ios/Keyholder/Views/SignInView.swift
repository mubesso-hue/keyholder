import SwiftUI
import AuthenticationServices
import CryptoKit
import Security

struct SignInView: View {
    @EnvironmentObject private var state: AppState
    @State private var nonce = ""

    var body: some View {
        VStack(spacing: 20) {
            Spacer()
            Image(systemName: "key.fill")
                .font(.system(size: 64))
                .foregroundStyle(.tint)
            Text("Keyholder")
                .font(.largeTitle.bold())
            Text("Block the apps that eat your time.\nOnly a friend can give it back.")
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
            Spacer()

            SignInWithAppleButton(.signIn) { request in
                nonce = Nonce.random()
                request.requestedScopes = [.fullName]
                request.nonce = Nonce.sha256(nonce)
            } onCompletion: { result in
                switch result {
                case .success(let authorization):
                    guard let credential = authorization.credential as? ASAuthorizationAppleIDCredential,
                          let tokenData = credential.identityToken,
                          let token = String(data: tokenData, encoding: .utf8) else {
                        state.errorMessage = "Apple did not return a sign-in token."
                        return
                    }
                    // Apple only sends the name on the very first sign-in.
                    let name = [credential.fullName?.givenName, credential.fullName?.familyName]
                        .compactMap { $0 }
                        .joined(separator: " ")
                    Task { await state.signIn(idToken: token, nonce: nonce, fullName: name.isEmpty ? nil : name) }
                case .failure(let error):
                    if (error as? ASAuthorizationError)?.code != .canceled {
                        state.errorMessage = error.localizedDescription
                    }
                }
            }
            .signInWithAppleButtonStyle(.black)
            .frame(height: 50)

            Text("Your keyholder sees your streak, your requests, and whether your block is on. Nothing else.")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .padding(24)
    }
}

enum Nonce {
    static func random(length: Int = 32) -> String {
        var bytes = [UInt8](repeating: 0, count: length)
        let status = SecRandomCopyBytes(kSecRandomDefault, length, &bytes)
        precondition(status == errSecSuccess, "Unable to generate nonce")
        let charset = Array("0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz-._")
        return String(bytes.map { charset[Int($0) % charset.count] })
    }

    static func sha256(_ input: String) -> String {
        SHA256.hash(data: Data(input.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}
