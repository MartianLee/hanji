import SwiftUI

enum PaletteMode { case commands, files }

@MainActor
final class UIState: ObservableObject {
    @Published var palette: PaletteMode?
}
