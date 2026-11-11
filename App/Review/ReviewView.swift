import SwiftUI

struct ReviewView: View {
    let projectID: UUID

    var body: some View {
        ContentUnavailableView("Ревью", systemImage: "scissors", description: Text("Скоро здесь будет монтаж."))
    }
}
