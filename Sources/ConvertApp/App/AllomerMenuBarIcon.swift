import AppKit
import SwiftUI

struct AllomerMenuBarIcon: View {
    @MainActor private static let templateImage: NSImage = {
        let svg = """
            <svg xmlns="http://www.w3.org/2000/svg" width="18" height="18" viewBox="0 0 18 18">
              <g fill="none" stroke="#000" stroke-width="3.38" stroke-linecap="butt">
                <path d="M12.39 4.34 A5.77 5.77 0 1 0 12.39 13.66"/>
                <path d="M12.86 4.72 A5.77 5.77 0 0 1 14.74 8.50"/>
                <path d="M14.74 9.50 A5.77 5.77 0 0 1 12.86 13.28"/>
              </g>
            </svg>
            """
        guard let image = NSImage(data: Data(svg.utf8)) else {
            preconditionFailure("The Allomer menu bar mark is invalid.")
        }
        image.size = NSSize(width: 18, height: 18)
        image.isTemplate = true
        return image
    }()

    var body: some View {
        Image(nsImage: Self.templateImage)
            .renderingMode(.template)
            .frame(width: 18, height: 18)
    }
}
