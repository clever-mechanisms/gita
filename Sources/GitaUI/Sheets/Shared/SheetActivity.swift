/// Where a review sheet is in its life: built, shown and idle, asking before a discard, applying its mutation, or
/// closing. One value, so a sheet can never apply while a confirmation is on screen, and a mutation that ends after the
/// sheet closed never reports into it.
enum SheetActivity: Equatable {
    /// Built but not shown yet: its first read starts when it appears, not when it is built.
    case built
    /// On screen and accepting input.
    case idle
    /// A discard confirmation is on screen.
    case prompting
    /// A reviewed mutation is running and the sheet cannot close until it ends. `refusedClose` records that a close
    /// or quit was refused meanwhile, so the status says why.
    case applying(refusedClose: Bool)
    /// The sheet is closing; late results are ignored. `applying` is true when the window closed under a running
    /// mutation: it still finishes, and quitting waits for it.
    case finishing(applying: Bool)

    var isApplying: Bool {
        switch self {
        case .applying, .finishing(applying: true): true
        case .built, .idle, .prompting, .finishing(applying: false): false
        }
    }
    var isPrompting: Bool { self == .prompting }
    var isFinishing: Bool { if case .finishing = self { true } else { false } }
    var refusedClose: Bool { self == .applying(refusedClose: true) }
    /// Controls accept input: nothing is being applied and the sheet is not closing.
    var isActive: Bool { !isApplying && !isFinishing }
    /// Active and no confirmation on screen.
    var isInteractive: Bool { self == .built || self == .idle }

    /// The sheet appeared; true the first time, when its first read should start.
    mutating func present() -> Bool {
        guard self == .built else { return false }
        self = .idle
        return true
    }
    /// A discard confirmation goes on screen; false when the sheet is not interactive.
    mutating func beginPrompt() -> Bool {
        guard isInteractive else { return false }
        self = .prompting
        return true
    }
    /// The confirmation was answered (a closing sheet stays closing).
    mutating func endPrompt() {
        if isPrompting { self = .idle }
    }
    /// The reviewed mutation starts; false when the sheet is busy, asking or closing.
    mutating func beginApply() -> Bool {
        guard isInteractive else { return false }
        self = .applying(refusedClose: false)
        return true
    }
    /// The mutation ended; false when the sheet closed meanwhile and its result must not touch the sheet.
    mutating func endApply() -> Bool {
        switch self {
        case .applying:
            self = .idle
            return true
        case .finishing(applying: true):
            self = .finishing(applying: false)
            return false
        case .built, .idle, .prompting, .finishing(applying: false):
            return false
        }
    }
    /// A close or quit was refused while applying.
    mutating func refuseClose() {
        if case .applying = self { self = .applying(refusedClose: true) }
    }
    /// The sheet is closing, possibly under a running mutation (its window closed regardless).
    mutating func finish() {
        if !isFinishing { self = .finishing(applying: isApplying) }
    }
}
