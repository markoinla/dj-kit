import SwiftUI

/// Spacing and corner radii, as in Wax Studio (`WaxSpace`, `WaxRadius`):
/// the web's `rounded-sm/md/lg/xl` map to 4 / 6 / 8 / 12 pt.
enum DJSpace {
    static let xxs: CGFloat = 2
    static let xs: CGFloat = 4
    static let sm: CGFloat = 8
    static let md: CGFloat = 12
    static let lg: CGFloat = 16
    static let xl: CGFloat = 20
    static let xxl: CGFloat = 24
    static let xxxl: CGFloat = 32
}

enum DJRadius {
    /// `rounded` — format tiles.
    static let sm: CGFloat = 4
    /// `rounded-md` — buttons, inputs.
    static let md: CGFloat = 6
    /// `rounded-lg` — cards.
    static let lg: CGFloat = 8
    /// `rounded-xl` — banners, trays, the drop zone.
    static let xl: CGFloat = 12
}

enum DJSize {
    /// The format tile on a sidebar row.
    static let sidebarTile: CGFloat = 32
    /// The format tile in a track's header.
    static let headerTile: CGFloat = 56
    /// The sidebar's width.
    static let sidebarMin: CGFloat = 250
    static let sidebarIdeal: CGFloat = 290
    static let sidebarMax: CGFloat = 380
    /// The detail column's widest measure.
    static let detailMaxWidth: CGFloat = 760
}
