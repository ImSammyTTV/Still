/// Session-level keys must work even when a capture toolbar control owns focus.
public enum CaptureKeyboardPolicy {
    public enum Action: Equatable { case cancel, beginWindowSelection, endWindowSelection, passThrough }
    public static func action(keyCode: UInt16, keyUp: Bool, editingText: Bool, windowSelectionAllowed: Bool, hasCommandModifier: Bool = false) -> Action {
        if keyCode == 53, !keyUp { return .cancel }
        guard keyCode == 49 else { return .passThrough }
        if keyUp { return .endWindowSelection }
        return windowSelectionAllowed && !editingText && !hasCommandModifier ? .beginWindowSelection : .passThrough
    }
}
