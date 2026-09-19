import AppKit

/// History popover: last 50 captures from GET /history, click-to-copy.
final class HistoryWindow: NSObject, NSPopoverDelegate {
    private let popover = NSPopover()
    private var rows: [SidecarClient.CaptureEntry] = []
    private var tableView: NSTableView!

    override init() {
        super.init()
        let table = NSTableView(frame: NSRect(x: 0, y: 0, width: 480, height: 360))
        table.headerView = nil
        table.rowHeight = 56
        let col = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("cell"))
        col.width = 460
        table.addTableColumn(col)
        table.dataSource = self
        table.delegate = self
        table.target = self
        table.action = #selector(copyClicked)
        tableView = table

        let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 480, height: 360))
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false

        let vc = NSViewController()
        vc.view = scroll
        vc.preferredContentSize = NSSize(width: 480, height: 360)

        popover.contentViewController = vc
        popover.behavior = .transient
        popover.contentSize = NSSize(width: 480, height: 360)
    }

    func toggle(relativeTo button: NSStatusBarButton) {
        if popover.isShown { popover.close(); return }
        SidecarClient.shared.history { [weak self] entries in
            DispatchQueue.main.async {
                guard let self = self else { return }
                self.rows = entries ?? []
                self.tableView.reloadData()
                self.popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
                self.popover.contentViewController?.view.window?.makeKey()
            }
        }
    }

    /// Single click copies the POLISHED text (brief AC7: click-to-copy).
    @objc private func copyClicked(_ sender: Any?) {
        let row = tableView?.clickedRow ?? -1
        guard rows.indices.contains(row) else { return }
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(rows[row].polished, forType: .string)
    }

    static let fmt: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "MMM d HH:mm"
        return f
    }()
}

extension HistoryWindow: NSTableViewDataSource, NSTableViewDelegate {
    func numberOfRows(in tableView: NSTableView) -> Int { rows.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let id = NSUserInterfaceItemIdentifier("cell")
        let cell: NSTableCellView
        if let reuse = tableView.makeView(withIdentifier: id, owner: self) as? NSTableCellView {
            cell = reuse
        } else {
            cell = NSTableCellView()
            let tf = NSTextField(labelWithString: "")
            tf.font = NSFont.systemFont(ofSize: 12)
            tf.textColor = .labelColor
            tf.maximumNumberOfLines = 2
            tf.lineBreakMode = .byTruncatingTail
            tf.translatesAutoresizingMaskIntoConstraints = false
            cell.addSubview(tf)
            cell.textField = tf
            NSLayoutConstraint.activate([
                tf.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 8),
                tf.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -8),
                tf.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
            ])
            cell.identifier = id
        }
        let entry = rows[row]
        let dateStr = HistoryWindow.fmt.string(from: Date(timeIntervalSince1970: entry.ts))
        cell.textField?.stringValue = "[\(entry.profile)] \(dateStr) — \(entry.polished)"
        return cell
    }
}
