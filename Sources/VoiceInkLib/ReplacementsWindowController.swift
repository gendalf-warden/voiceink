import AppKit
import Foundation

/// Editor for the user replacements dictionary (Whisper output → corrected form).
/// Shows a 2-column table (From / To) with Add/Remove buttons.
/// Auto-saves to config on every edit.
public class ReplacementsWindowController: NSObject, NSWindowDelegate, NSTableViewDataSource, NSTableViewDelegate, NSSearchFieldDelegate {
    private var window: NSWindow?
    private var tableView: NSTableView!
    private var searchField: NSSearchField!
    /// Master data — full list of replacements
    private var pairs: [(from: String, to: String)] = []
    /// Indices into `pairs` that pass the current search filter
    private var filteredIndices: [Int] = []
    private var searchText: String = ""

    private var config: Config
    public var onConfigChanged: ((Config) -> Void)?

    public init(config: Config) {
        self.config = config
        super.init()
        loadPairs()
    }

    public func updateConfig(_ config: Config) {
        self.config = config
        loadPairs()
        tableView?.reloadData()
    }

    private func loadPairs() {
        // Sort by `from` for stable display order
        pairs = config.replacements
            .map { (from: $0.key, to: $0.value) }
            .sorted { $0.from.localizedCaseInsensitiveCompare($1.from) == .orderedAscending }
        applyFilter()
    }

    /// Recompute filteredIndices based on current searchText
    private func applyFilter() {
        if searchText.isEmpty {
            filteredIndices = Array(0..<pairs.count)
            return
        }
        let needle = searchText.lowercased()
        filteredIndices = pairs.enumerated().compactMap { (i, pair) in
            if pair.from.lowercased().contains(needle) || pair.to.lowercased().contains(needle) {
                return i
            }
            return nil
        }
    }

    private func saveToConfig() {
        var dict: [String: String] = [:]
        for p in pairs where !p.from.isEmpty {
            dict[p.from] = p.to
        }
        config.replacements = dict
        config.save()
        onConfigChanged?(config)
    }

    public func showWindow() {
        if let existing = window, existing.isVisible {
            NSApp.showDock()
            existing.makeKeyAndOrderFront(nil)
            return
        }

        let width: CGFloat = 540
        let height: CGFloat = 400
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: width, height: height),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered, defer: false
        )
        window.title = "Replacements"
        window.center()
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.minSize = NSSize(width: 400, height: 320)

        let contentView = NSView(frame: NSRect(x: 0, y: 0, width: width, height: height))
        contentView.autoresizingMask = [.width, .height]
        window.contentView = contentView

        // --- Hint at the top ---
        let hint = NSTextField(wrappingLabelWithString:
            "Замены применяются к тексту от Whisper до пунктуации LLM. " +
            "Например: «Демале» → «ДеМоле». Поиск по границе слова, регистро-независимый.")
        hint.frame = NSRect(x: 16, y: height - 50, width: width - 32, height: 32)
        hint.font = NSFont.systemFont(ofSize: 11)
        hint.textColor = .secondaryLabelColor
        hint.autoresizingMask = [.width, .minYMargin]
        contentView.addSubview(hint)

        // --- Search field (live filter) ---
        searchField = NSSearchField(frame: NSRect(x: 16, y: height - 92, width: width - 32, height: 24))
        searchField.placeholderString = "Search replacements…"
        searchField.sendsSearchStringImmediately = true
        searchField.sendsWholeSearchString = false
        searchField.target = self
        searchField.action = #selector(searchChanged)
        searchField.delegate = self  // for live filter on every keystroke
        searchField.autoresizingMask = [.width, .minYMargin]
        contentView.addSubview(searchField)

        // --- Table in scroll view ---
        let scrollView = NSScrollView(frame: NSRect(x: 16, y: 60, width: width - 32, height: height - 160))
        scrollView.autoresizingMask = [.width, .height]
        scrollView.hasVerticalScroller = true
        scrollView.borderType = .bezelBorder

        tableView = NSTableView()
        tableView.autoresizingMask = [.width]
        tableView.usesAlternatingRowBackgroundColors = true
        tableView.allowsMultipleSelection = false
        tableView.rowHeight = 22

        let fromCol = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("from"))
        fromCol.title = "From (Whisper)"
        fromCol.width = (width - 50) / 2
        fromCol.minWidth = 100

        let toCol = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("to"))
        toCol.title = "To (corrected)"
        toCol.width = (width - 50) / 2
        toCol.minWidth = 100

        tableView.addTableColumn(fromCol)
        tableView.addTableColumn(toCol)
        tableView.dataSource = self
        tableView.delegate = self
        // Single click anywhere on a cell enters edit mode immediately
        tableView.target = self
        tableView.action = #selector(tableClicked)

        scrollView.documentView = tableView
        contentView.addSubview(scrollView)

        // --- Add / Remove buttons (native macOS style: small square, SF symbols) ---
        let addImage = NSImage(systemSymbolName: "plus", accessibilityDescription: "Add")
        let removeImage = NSImage(systemSymbolName: "minus", accessibilityDescription: "Remove")

        let addButton = NSButton(image: addImage ?? NSImage(), target: self, action: #selector(addRow))
        addButton.frame = NSRect(x: 16, y: 16, width: 28, height: 24)
        addButton.bezelStyle = .smallSquare
        addButton.imageScaling = .scaleProportionallyDown
        addButton.autoresizingMask = [.maxXMargin, .maxYMargin]
        contentView.addSubview(addButton)

        let removeButton = NSButton(image: removeImage ?? NSImage(), target: self, action: #selector(removeRow))
        removeButton.frame = NSRect(x: 44, y: 16, width: 28, height: 24)
        removeButton.bezelStyle = .smallSquare
        removeButton.imageScaling = .scaleProportionallyDown
        removeButton.autoresizingMask = [.maxXMargin, .maxYMargin]
        contentView.addSubview(removeButton)

        // --- Close button ---
        let closeButton = NSButton(title: "Close", target: self, action: #selector(closeWindow))
        closeButton.frame = NSRect(x: width - 96, y: 14, width: 80, height: 32)
        closeButton.bezelStyle = .rounded
        closeButton.keyEquivalent = "\r"
        closeButton.autoresizingMask = [.minXMargin, .maxYMargin]
        contentView.addSubview(closeButton)

        self.window = window
        NSApp.showDock()
        window.makeKeyAndOrderFront(nil)
    }

    @objc private func addRow() {
        // New rows always show (regardless of search) — clear search to make sure user sees it
        if !searchText.isEmpty {
            searchField.stringValue = ""
            searchText = ""
            applyFilter()
        }
        pairs.append((from: "", to: ""))
        applyFilter()
        tableView.reloadData()
        let row = filteredIndices.count - 1
        tableView.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        tableView.scrollRowToVisible(row)
        // Start editing the "from" cell of the new row
        DispatchQueue.main.async { [weak self] in
            self?.tableView.editColumn(0, row: row, with: nil, select: true)
        }
    }

    @objc private func removeRow() {
        let displayedRow = tableView.selectedRow
        guard displayedRow >= 0 && displayedRow < filteredIndices.count else { return }
        let actualIndex = filteredIndices[displayedRow]
        pairs.remove(at: actualIndex)
        applyFilter()
        tableView.reloadData()
        saveToConfig()
    }

    @objc private func closeWindow() {
        window?.close()
    }

    @objc private func tableClicked() {
        let row = tableView.clickedRow
        let col = tableView.clickedColumn
        guard row >= 0, row < filteredIndices.count, col >= 0 else { return }
        tableView.editColumn(col, row: row, with: nil, select: true)
    }

    @objc private func searchChanged() {
        searchText = searchField.stringValue
        applyFilter()
        tableView.reloadData()
    }

    // MARK: - NSSearchFieldDelegate / NSTextFieldDelegate
    public func controlTextDidChange(_ obj: Notification) {
        guard let field = obj.object as? NSSearchField, field === searchField else { return }
        searchChanged()
    }

    // MARK: - NSTableViewDataSource

    public func numberOfRows(in tableView: NSTableView) -> Int {
        filteredIndices.count
    }

    public func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard row < filteredIndices.count, let column = tableColumn else { return nil }
        let actualIndex = filteredIndices[row]
        let identifier = NSUserInterfaceItemIdentifier("cell-\(column.identifier.rawValue)")
        let cell: NSTableCellView
        if let reused = tableView.makeView(withIdentifier: identifier, owner: self) as? NSTableCellView {
            cell = reused
        } else {
            cell = NSTableCellView()
            cell.identifier = identifier
            let text = NSTextField()
            text.isBordered = false
            text.drawsBackground = false
            text.isEditable = true
            text.translatesAutoresizingMaskIntoConstraints = false
            text.target = self
            text.action = #selector(cellEdited(_:))
            // Save on ANY edit completion (Enter, Tab, focus loss) — not just Enter
            text.cell?.sendsActionOnEndEditing = true
            cell.addSubview(text)
            cell.textField = text
            NSLayoutConstraint.activate([
                text.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 4),
                text.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -4),
                text.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
            ])
        }
        let value = column.identifier.rawValue == "from" ? pairs[actualIndex].from : pairs[actualIndex].to
        cell.textField?.stringValue = value
        // Encode actual index (not displayed row) so editing works through filter
        cell.textField?.tag = actualIndex * 10 + (column.identifier.rawValue == "from" ? 0 : 1)
        return cell
    }

    @objc private func cellEdited(_ sender: NSTextField) {
        let actualIndex = sender.tag / 10
        let isFromCol = sender.tag % 10 == 0
        guard actualIndex >= 0 && actualIndex < pairs.count else { return }
        if isFromCol {
            pairs[actualIndex].from = sender.stringValue
        } else {
            pairs[actualIndex].to = sender.stringValue
        }
        saveToConfig()
    }

    // MARK: - NSWindowDelegate
    public func windowWillClose(_ notification: Notification) {
        // Force-commit any in-progress edit (resigns first responder → triggers cellEdited)
        window?.makeFirstResponder(nil)
        saveToConfig()
        window = nil
        NSApp.hideDockIfNoWindows()
    }
}
