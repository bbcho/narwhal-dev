import AppKit
import NarwhalCore

@MainActor
final class ManagedRulesEditorController: NSObject {
    typealias SaveRules = ([ManagedWindowRule]) async throws -> Void

    private var rules: [ManagedWindowRule]
    private let matchCounts: [ManagedRuleID: Int]
    private let saveRules: SaveRules
    private weak var parentWindow: NSWindow?
    private var sheet: NSWindow?
    private var selectedIndex: Int?

    private let rulesPopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private let enabledButton = NSButton(checkboxWithTitle: "Enabled", target: nil, action: nil)
    private let nameField = NSTextField()
    private let bundleField = NSTextField()
    private let titleRegexField = NSTextField()
    private let roleField = NSTextField()
    private let placementPopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private let placementValueField = NSTextField()
    private let excludeFocusButton = NSButton(checkboxWithTitle: "Exclude from focus cycle", target: nil, action: nil)
    private let minimumWidthField = NSTextField()
    private let minimumHeightField = NSTextField()
    private let errorLabel = NSTextField(wrappingLabelWithString: "")
    private let saveButton = NSButton(title: "Save Rules", target: nil, action: nil)

    init(
        rules: [ManagedWindowRule],
        matchCounts: [ManagedRuleID: Int] = [:],
        saveRules: @escaping SaveRules
    ) {
        self.rules = rules
        self.matchCounts = matchCounts
        self.saveRules = saveRules
        super.init()
    }

    func beginSheet(for parent: NSWindow) {
        parentWindow = parent
        let sheet = makeSheet()
        self.sheet = sheet
        renderRuleList(selecting: rules.isEmpty ? nil : 0)
        parent.beginSheet(sheet)
    }

    func debugRuleTitles() -> [String] {
        rulesPopup.itemTitles
    }

    func debugEditName(_ name: String) {
        nameField.stringValue = name
    }

    func debugSelectRule(at index: Int) {
        rulesPopup.selectItem(at: index)
        selectRule()
    }

    func debugRuleNames() -> [String] {
        rules.map(\.name)
    }

    func debugSelectedIndex() -> Int? {
        selectedIndex
    }

    private func makeSheet() -> NSWindow {
        let sheet = NSWindow(
            contentRect: CGRect(x: 0, y: 0, width: 620, height: 530),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        sheet.title = "Managed Window Rules"
        sheet.contentView = makeContentView()
        return sheet
    }

    private func makeContentView() -> NSView {
        let root = NSView()
        let heading = NSTextField(labelWithString: "ORDERED RULES · FIRST MATCH WINS BEFORE LUA")
        heading.font = .monospacedSystemFont(ofSize: 10, weight: .semibold)
        heading.textColor = .secondaryLabelColor
        heading.translatesAutoresizingMaskIntoConstraints = false

        rulesPopup.target = self
        rulesPopup.action = #selector(selectRule)
        rulesPopup.setAccessibilityLabel("Managed rule")
        rulesPopup.translatesAutoresizingMaskIntoConstraints = false
        let add = button("Add", #selector(addRule), "Add a new managed rule")
        let remove = button("Delete…", #selector(deleteRule), "Delete the selected rule after confirmation")
        let up = button("Move Up", #selector(moveRuleUp), "Increase this rule's precedence")
        let down = button("Move Down", #selector(moveRuleDown), "Decrease this rule's precedence")
        let ruleBar = NSStackView(views: [rulesPopup, add, remove, up, down])
        ruleBar.orientation = .horizontal
        ruleBar.spacing = 8
        ruleBar.translatesAutoresizingMaskIntoConstraints = false
        rulesPopup.widthAnchor.constraint(greaterThanOrEqualToConstant: 200).isActive = true

        placementPopup.addItems(withTitles: ["Default", "Float", "Ignore", "Display Slot", "Zone"])
        placementPopup.target = self
        placementPopup.action = #selector(placementChanged)
        placementPopup.setAccessibilityLabel("Placement policy")

        configure(field: nameField, label: "Rule name", placeholder: "Descriptive name")
        configure(field: bundleField, label: "Bundle identifier", placeholder: "com.example.app")
        configure(field: titleRegexField, label: "Title regular expression", placeholder: "Optional")
        configure(field: roleField, label: "Accessibility role", placeholder: "Optional, e.g. AXWindow")
        configure(field: placementValueField, label: "Placement value", placeholder: "Display slot or zone ID")
        configure(field: minimumWidthField, label: "Minimum width", placeholder: "Optional points")
        configure(field: minimumHeightField, label: "Minimum height", placeholder: "Optional points")
        enabledButton.setAccessibilityHelp("Disabled rules remain saved but never match")
        excludeFocusButton.setAccessibilityHelp("Prevents matching floating windows from appearing in focus cycle")

        let grid = NSGridView(views: [
            [label("Name"), nameField],
            [label("Bundle ID"), bundleField],
            [label("Title regex"), titleRegexField],
            [label("AX role"), roleField],
            [label("Placement"), placementPopup],
            [label("Slot / zone"), placementValueField],
            [label("Minimum width"), minimumWidthField],
            [label("Minimum height"), minimumHeightField]
        ])
        grid.rowSpacing = 8
        grid.columnSpacing = 12
        grid.column(at: 0).xPlacement = .trailing
        grid.column(at: 1).xPlacement = .fill
        grid.translatesAutoresizingMaskIntoConstraints = false

        let flags = NSStackView(views: [enabledButton, excludeFocusButton])
        flags.orientation = .horizontal
        flags.spacing = 18
        flags.translatesAutoresizingMaskIntoConstraints = false

        errorLabel.textColor = .systemRed
        errorLabel.isHidden = true
        errorLabel.translatesAutoresizingMaskIntoConstraints = false

        let commit = button("Update Rule", #selector(updateRule), "Validate and stage edits to this rule")
        let cancel = button("Cancel", #selector(cancel), "Close without saving managed rules")
        saveButton.target = self
        saveButton.action = #selector(save)
        saveButton.keyEquivalent = "\r"
        saveButton.setAccessibilityHelp("Atomically save all staged rules and activate them")
        let footer = NSStackView(views: [commit, NSView(), cancel, saveButton])
        footer.orientation = .horizontal
        footer.spacing = 8
        footer.translatesAutoresizingMaskIntoConstraints = false

        [heading, ruleBar, grid, flags, errorLabel, footer].forEach(root.addSubview)
        NSLayoutConstraint.activate([
            heading.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 20),
            heading.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -20),
            heading.topAnchor.constraint(equalTo: root.topAnchor, constant: 18),
            ruleBar.leadingAnchor.constraint(equalTo: heading.leadingAnchor),
            ruleBar.trailingAnchor.constraint(equalTo: heading.trailingAnchor),
            ruleBar.topAnchor.constraint(equalTo: heading.bottomAnchor, constant: 10),
            grid.leadingAnchor.constraint(equalTo: heading.leadingAnchor),
            grid.trailingAnchor.constraint(equalTo: heading.trailingAnchor),
            grid.topAnchor.constraint(equalTo: ruleBar.bottomAnchor, constant: 18),
            flags.leadingAnchor.constraint(equalTo: heading.leadingAnchor, constant: 124),
            flags.trailingAnchor.constraint(lessThanOrEqualTo: heading.trailingAnchor),
            flags.topAnchor.constraint(equalTo: grid.bottomAnchor, constant: 12),
            errorLabel.leadingAnchor.constraint(equalTo: heading.leadingAnchor),
            errorLabel.trailingAnchor.constraint(equalTo: heading.trailingAnchor),
            errorLabel.topAnchor.constraint(equalTo: flags.bottomAnchor, constant: 12),
            footer.leadingAnchor.constraint(equalTo: heading.leadingAnchor),
            footer.trailingAnchor.constraint(equalTo: heading.trailingAnchor),
            footer.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -18)
        ])
        return root
    }

    private func renderRuleList(selecting index: Int?) {
        rulesPopup.removeAllItems()
        if rules.isEmpty {
            rulesPopup.addItem(withTitle: "No managed rules")
            rulesPopup.isEnabled = false
            selectedIndex = nil
            clearForm()
        } else {
            rulesPopup.isEnabled = true
            rulesPopup.addItems(withTitles: rules.enumerated().map { index, rule in
                let count = matchCounts[rule.id, default: 0]
                let state = rule.isEnabled ? "" : " · disabled"
                return "\(index + 1). \(rule.name) · \(count) current\(state)"
            })
            let selected = min(max(index ?? 0, 0), rules.count - 1)
            selectedIndex = selected
            rulesPopup.selectItem(at: selected)
            loadForm(rules[selected])
        }
        saveButton.isEnabled = true
    }

    private func loadForm(_ rule: ManagedWindowRule) {
        enabledButton.state = rule.isEnabled ? .on : .off
        nameField.stringValue = rule.name
        bundleField.stringValue = rule.matcher.bundleID ?? ""
        titleRegexField.stringValue = rule.matcher.titleRegex ?? ""
        roleField.stringValue = rule.matcher.role ?? ""
        excludeFocusButton.state = rule.policy.excludeFromFocusCycle ? .on : .off
        minimumWidthField.stringValue = rule.policy.minimumWidth.map(numberText) ?? ""
        minimumHeightField.stringValue = rule.policy.minimumHeight.map(numberText) ?? ""
        switch rule.policy.placement {
        case .defaultBehavior:
            placementPopup.selectItem(at: 0)
            placementValueField.stringValue = ""
        case .forceFloat:
            placementPopup.selectItem(at: 1)
            placementValueField.stringValue = ""
        case .ignore:
            placementPopup.selectItem(at: 2)
            placementValueField.stringValue = ""
        case .displaySlot(let slot):
            placementPopup.selectItem(at: 3)
            placementValueField.stringValue = String(slot)
        case .zone(let zoneID):
            placementPopup.selectItem(at: 4)
            placementValueField.stringValue = zoneID.raw
        }
        placementChanged()
        hideError()
    }

    private func clearForm() {
        [nameField, bundleField, titleRegexField, roleField, placementValueField, minimumWidthField, minimumHeightField]
            .forEach { $0.stringValue = "" }
        enabledButton.state = .on
        excludeFocusButton.state = .off
        placementPopup.selectItem(at: 0)
        placementChanged()
    }

    @objc private func selectRule() {
        let newIndex = rulesPopup.indexOfSelectedItem
        guard rules.indices.contains(newIndex) else { return }
        let previousIndex = selectedIndex
        guard stageSelectedRule() else {
            if let previousIndex { rulesPopup.selectItem(at: previousIndex) }
            return
        }
        selectedIndex = newIndex
        loadForm(rules[newIndex])
    }

    @objc private func addRule() {
        guard stageSelectedRule() else { return }
        let rule = ManagedWindowRule(
            id: ManagedRuleID(rawValue: UUID().uuidString.lowercased()),
            name: "New Rule",
            matcher: ManagedRuleMatcher(bundleID: "com.example.app"),
            policy: ManagedRulePolicy()
        )
        rules.append(rule)
        renderRuleList(selecting: rules.count - 1)
        nameField.selectText(nil)
    }

    @objc private func deleteRule() {
        guard let selectedIndex, rules.indices.contains(selectedIndex), let sheet else { return }
        let rule = rules[selectedIndex]
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Delete “\(rule.name)”?"
        alert.informativeText = "Future windows will no longer use this managed policy. The change takes effect only after Save Rules."
        alert.addButton(withTitle: "Delete")
        alert.addButton(withTitle: "Cancel")
        alert.beginSheetModal(for: sheet) { [weak self] response in
            guard response == .alertFirstButtonReturn, let self else { return }
            self.rules.remove(at: selectedIndex)
            self.renderRuleList(selecting: min(selectedIndex, self.rules.count - 1))
        }
    }

    @objc private func moveRuleUp() {
        guard stageSelectedRule(), let selectedIndex, selectedIndex > 0 else { return }
        rules.swapAt(selectedIndex, selectedIndex - 1)
        renderRuleList(selecting: selectedIndex - 1)
    }

    @objc private func moveRuleDown() {
        guard stageSelectedRule(), let selectedIndex, selectedIndex + 1 < rules.count else { return }
        rules.swapAt(selectedIndex, selectedIndex + 1)
        renderRuleList(selecting: selectedIndex + 1)
    }

    @objc private func placementChanged() {
        let needsValue = placementPopup.indexOfSelectedItem == 3 || placementPopup.indexOfSelectedItem == 4
        placementValueField.isEnabled = needsValue
        placementValueField.placeholderString = placementPopup.indexOfSelectedItem == 3
            ? "Zero-based display slot"
            : placementPopup.indexOfSelectedItem == 4 ? "Configured zone ID" : "Not used"
    }

    @objc private func updateRule() {
        guard let selectedIndex, stageSelectedRule() else { return }
        renderRuleList(selecting: selectedIndex)
    }

    @objc private func save() {
        guard stageSelectedRule() else { return }
        saveButton.isEnabled = false
        Task {
            do {
                try await saveRules(rules)
                closeSheet()
            } catch {
                saveButton.isEnabled = true
                showError("Rules were not saved or activated: \(error)")
            }
        }
    }

    @objc private func cancel() {
        closeSheet()
    }

    private func closeSheet() {
        guard let parentWindow, let sheet else { return }
        parentWindow.endSheet(sheet)
        self.sheet = nil
    }

    private func ruleFromForm(id: ManagedRuleID) -> RuleFormResult<ManagedWindowRule> {
        let name = trimmed(nameField.stringValue)
        guard !name.isEmpty else { return .failure("Enter a descriptive rule name.") }
        let matcher = ManagedRuleMatcher(
            bundleID: optional(bundleField.stringValue),
            titleRegex: optional(titleRegexField.stringValue),
            role: optional(roleField.stringValue)
        )
        guard matcher.bundleID != nil || matcher.titleRegex != nil || matcher.role != nil else {
            return .failure("Enter at least one bundle ID, title regex, or AX role matcher.")
        }
        let placement: ManagedRulePlacement
        switch placementPopup.indexOfSelectedItem {
        case 0: placement = .defaultBehavior
        case 1: placement = .forceFloat
        case 2: placement = .ignore
        case 3:
            guard let slot = Int(trimmed(placementValueField.stringValue)), slot >= 0 else {
                return .failure("Display slot must be a zero-based whole number.")
            }
            placement = .displaySlot(slot)
        case 4:
            let zone = trimmed(placementValueField.stringValue)
            guard !zone.isEmpty else { return .failure("Enter an existing configured zone ID.") }
            placement = .zone(ZoneID(raw: zone))
        default:
            return .failure("Choose a placement policy.")
        }
        let minimumWidth: Double?
        let minimumHeight: Double?
        switch optionalPositiveDouble(minimumWidthField.stringValue, field: "Minimum width") {
        case .failure(let error): return .failure(error)
        case .success(let value): minimumWidth = value
        }
        switch optionalPositiveDouble(minimumHeightField.stringValue, field: "Minimum height") {
        case .failure(let error): return .failure(error)
        case .success(let value): minimumHeight = value
        }
        return .success(ManagedWindowRule(
            id: id,
            name: name,
            isEnabled: enabledButton.state == .on,
            matcher: matcher,
            policy: ManagedRulePolicy(
                placement: placement,
                excludeFromFocusCycle: excludeFocusButton.state == .on,
                minimumWidth: minimumWidth,
                minimumHeight: minimumHeight
            )
        ))
    }

    private func stageSelectedRule() -> Bool {
        guard let selectedIndex, rules.indices.contains(selectedIndex) else { return true }
        let updatedRule: ManagedWindowRule
        switch ruleFromForm(id: rules[selectedIndex].id) {
        case .failure(let message):
            showError(message)
            return false
        case .success(let rule):
            updatedRule = rule
        }
        let updated = rules.enumerated().map { $0.offset == selectedIndex ? updatedRule : $0.element }
        if case .failure(let error) = validateManagedRules(updated) {
            showError(validationMessage(error))
            return false
        }
        rules = updated
        hideError()
        return true
    }

    private func showError(_ message: String) {
        errorLabel.stringValue = message
        errorLabel.isHidden = false
    }

    private func hideError() {
        errorLabel.stringValue = ""
        errorLabel.isHidden = true
    }

    private func button(_ title: String, _ action: Selector, _ help: String) -> NSButton {
        let button = NSButton(title: title, target: self, action: action)
        button.bezelStyle = .rounded
        button.controlSize = .small
        button.toolTip = help
        button.setAccessibilityHelp(help)
        return button
    }

    private func label(_ text: String) -> NSTextField {
        let field = NSTextField(labelWithString: text)
        field.textColor = .secondaryLabelColor
        return field
    }

    private func configure(field: NSTextField, label: String, placeholder: String) {
        field.placeholderString = placeholder
        field.setAccessibilityLabel(label)
    }
}

private enum RuleFormResult<Value> {
    case success(Value)
    case failure(String)
}

private func optionalPositiveDouble(_ text: String, field: String) -> RuleFormResult<Double?> {
    let text = trimmed(text)
    guard !text.isEmpty else { return .success(nil) }
    guard let value = Double(text), value.isFinite, value > 0 else {
        return .failure("\(field) must be a positive number of points.")
    }
    return .success(value)
}

private func optional(_ text: String) -> String? {
    let value = trimmed(text)
    return value.isEmpty ? nil : value
}

private func trimmed(_ text: String) -> String {
    text.trimmingCharacters(in: .whitespacesAndNewlines)
}

private func numberText(_ value: Double) -> String {
    value.rounded() == value ? String(format: "%.0f", value) : String(value)
}

private func validationMessage(_ error: ManagedRuleValidationError) -> String {
    switch error {
    case .emptyID, .duplicateID:
        return "A rule has an invalid or duplicate internal identifier. Remove and recreate that rule."
    case .emptyName(let index):
        return "Rule \(index + 1) needs a descriptive name."
    case .emptyMatcher(let index):
        return "Rule \(index + 1) needs at least one matcher."
    case .invalidTitleRegex(let index, let pattern):
        return "Rule \(index + 1) has an invalid title regular expression: \(pattern)"
    case .invalidDisplaySlot(let index, _):
        return "Rule \(index + 1) has an invalid display slot."
    case .emptyZone(let index):
        return "Rule \(index + 1) needs a configured zone ID."
    case .invalidMinimumWidth(let index):
        return "Rule \(index + 1) has an invalid minimum width."
    case .invalidMinimumHeight(let index):
        return "Rule \(index + 1) has an invalid minimum height."
    }
}
