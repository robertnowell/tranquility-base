import Foundation

/// How the grid arranges the rows it has already chosen into folders.
///
/// The grid decides WHICH agents it draws exactly as before
/// (`SessionRow.gridRows`); this only decides where each one goes. Ruled
/// 29 Sep 2026, `docs/rulings/ruling-project-folders.md`:
///
/// 1. Folders sit above the loose rows.
/// 2. Inside a folder the lamp order is the grid's own, unchanged:
///    `SessionRow.quietRowsLast`, green and amber by recency, then blue.
/// 3. Folders keep the order the user dragged them into. A lamp lighting
///    never moves a folder (re-ruled 29 Sep 2026: rise-to-top made a folder
///    dragged above another snap back as soon as the other lit up).
/// 4. A collapsed folder is one header wearing its most urgent lamp and a
///    count of its lit agents. The lamp is solid only when a member's lamp
///    is: green or amber that has been heard draws hollow on the header as on
///    the row (1 Oct 2026, "collapsed should show solid green only when
///    containing solid green lamp").
/// 5. A folder with nothing on the grid is not drawn, and is not deleted.
public enum ProjectLayout {

    public enum Line: Equatable, Sendable {
        /// A folder's header. `lamp`, `hollow` and `lit` describe its members
        /// when it is collapsed; an open folder's header wears no lamp, its
        /// rows do.
        case header(ProjectBook.Folder, lamp: Lamp?, hollow: Bool, lit: Int, members: Int)
        /// A row, and the folder it is drawn inside (nil when loose).
        case row(SessionRow, folder: String?)

        public var row: SessionRow? {
            if case let .row(row, _) = self { return row }
            return nil
        }
        public var folder: ProjectBook.Folder? {
            if case let .header(folder, _, _, _, _) = self { return folder }
            return nil
        }
    }

    public static func lines(_ shown: [SessionRow], book: ProjectBook,
                             origin: (String) -> String = { $0 }) -> [Line] {
        let groups = arrange(shown, book: book, origin: origin)
        var lines: [Line] = []
        for group in groups.folders {
            let lit = group.rows.filter { $0.lamp.isLit }
            if group.folder.collapsed {
                let lamp = lit.first?.lamp
                // Hollow when every member wearing this lamp has been heard:
                // the same test GridRowView applies to each row.
                let hollow = lamp.map { lamp in
                    lamp.asksForYou && !lit.contains { $0.lamp == lamp && $0.read != .opened }
                } ?? false
                lines.append(.header(group.folder, lamp: lamp, hollow: hollow,
                                     lit: lit.count, members: group.rows.count))
            } else {
                lines.append(.header(group.folder, lamp: nil, hollow: false, lit: lit.count,
                                     members: group.rows.count))
                lines += group.rows.map { .row($0, folder: group.folder.id) }
            }
        }
        lines += groups.loose.map { .row($0, folder: nil) }
        return lines
    }

    public struct Arrangement: Equatable, Sendable {
        public var folders: [(folder: ProjectBook.Folder, rows: [SessionRow])]
        public var loose: [SessionRow]
        public static func == (a: Arrangement, b: Arrangement) -> Bool {
            a.loose == b.loose && a.folders.map(\.folder) == b.folders.map(\.folder)
                && a.folders.map(\.rows) == b.folders.map(\.rows)
        }
    }

    /// Folders in drawing order with their rows in lamp order, then the loose
    /// rows. Shared by the panel and by `tbase targets`, so the two never
    /// disagree about the order.
    public static func arrange(_ shown: [SessionRow], book: ProjectBook,
                               origin: (String) -> String = { $0 }) -> Arrangement {
        var byFolder: [String: [SessionRow]] = [:]
        var loose: [SessionRow] = []
        for row in shown {
            if let folder = book.folder(of: row.id, origin: origin) {
                byFolder[folder.id, default: []].append(row)
            } else {
                loose.append(row)
            }
        }
        // Rule 3: the user's order, exactly. Only the rows inside a folder
        // move with their lamps.
        let present = book.folders.filter { !(byFolder[$0.id]?.isEmpty ?? true) }
        return Arrangement(
            folders: present.map { ($0, SessionRow.quietRowsLast(byFolder[$0.id] ?? [])) },
            loose: SessionRow.quietRowsLast(loose))
    }

    /// Header count, for the panel's height budget: a header is shorter than
    /// a row but not free.
    public static func headerCount(_ shown: [SessionRow], book: ProjectBook,
                                   origin: (String) -> String = { $0 }) -> Int {
        arrange(shown, book: book, origin: origin).folders.count
    }
}
