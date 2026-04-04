/// Generic undo/redo stack with a configurable maximum depth.
///
/// When the stack exceeds `maxDepth`, the oldest undo action is discarded.
/// Pushing a new action clears the redo stack.
public final class UndoStack<Action> {

    public let maxDepth: Int

    private var undoActions: [Action] = []
    private var redoActions: [Action] = []

    public init(maxDepth: Int = 50) {
        self.maxDepth = maxDepth
    }

    public var canUndo: Bool { !undoActions.isEmpty }
    public var canRedo: Bool { !redoActions.isEmpty }

    /// Push a new action onto the undo stack. Clears redo history.
    public func push(_ action: Action) {
        undoActions.append(action)
        if undoActions.count > maxDepth {
            undoActions.removeFirst()
        }
        redoActions.removeAll()
    }

    /// Pop the most recent action from the undo stack. Returns nil if empty.
    /// The popped action is moved to the redo stack.
    @discardableResult
    public func undo() -> Action? {
        guard let action = undoActions.popLast() else { return nil }
        redoActions.append(action)
        return action
    }

    /// Pop the most recent action from the redo stack. Returns nil if empty.
    /// The popped action is moved back to the undo stack.
    @discardableResult
    public func redo() -> Action? {
        guard let action = redoActions.popLast() else { return nil }
        undoActions.append(action)
        return action
    }

    /// Clear all undo and redo history.
    public func clear() {
        undoActions.removeAll()
        redoActions.removeAll()
    }
}
