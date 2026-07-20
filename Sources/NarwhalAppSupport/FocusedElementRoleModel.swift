public func isFocusedWindowContainer(role: String, subrole: String) -> Bool {
    role == "AXWindow"
        || role == "AXSheet"
        || role == "AXDialog"
        || subrole == "AXDialog"
        || subrole == "AXSystemDialog"
}

public func isTransientFocusedWindow(role: String, subrole: String) -> Bool {
    role == "AXSheet"
        || role == "AXDialog"
        || subrole == "AXDialog"
        || subrole == "AXSystemDialog"
}
