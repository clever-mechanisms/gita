/// The status row's content: a message, a spinner while busy, red for errors.
struct SheetStatus: Equatable {
    var message: String
    var isBusy = false
    var isError = false
}
