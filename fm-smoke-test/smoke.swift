import Foundation
import FoundationModels

@Generable
struct SmokeResult {
    let word: String
}

func runSmoke() async {
    print("=== FM Smoke Test ===")
    print("Step 1: Creating session...")
    do {
        let session = LanguageModelSession()
        print("Step 2: Session created. Sending prompt...")
        let response = try await session.respond(
            to: "Return the word 'hello'",
            generating: SmokeResult.self
        )
        print("Step 3: Got response.")
        print("Result: \(response.content)")
        print("=== SUCCESS ===")
    } catch {
        print("=== ERROR ===")
        print("Type: \(type(of: error))")
        print("Description: \(error)")
        print("Localized: \(error.localizedDescription)")
        if let nsError = error as NSError? {
            print("Domain: \(nsError.domain)")
            print("Code: \(nsError.code)")
            print("UserInfo: \(nsError.userInfo)")
        }
    }
}

let semaphore = DispatchSemaphore(value: 0)
Task {
    await runSmoke()
    semaphore.signal()
}
semaphore.wait()
