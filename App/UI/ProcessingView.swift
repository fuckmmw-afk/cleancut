import SwiftUI

struct ProcessingView: View {
    let projectID: UUID
    var onFinished: () -> Void

    var body: some View {
        ContentUnavailableView("Обработка", systemImage: "hourglass", description: Text("Скоро здесь будет анализ."))
    }
}
