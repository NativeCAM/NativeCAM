import AppKit
import CAMCore
import SwiftUI
import UniformTypeIdentifiers

/// Standard editing commands the canvas forwards from the responder chain (Edit menu, keyboard).
enum CanvasCommand {
    case selectAll, delete, cut, copy, paste, duplicate, deselect
}

/// What the Metal canvas asks of the app. All points are design-space millimetres on the material top (z = 0).
@MainActor
protocol ViewportInteractionDelegate: AnyObject {
    /// Mouse went down on the canvas. Return true to take the drag (moving shapes); false lets the canvas
    /// orbit / marquee instead.
    func viewportMouseDown(at p: Vec2, tolerance: Double, modifiers: NSEvent.ModifierFlags) -> Bool
    func viewportDragMoved(to p: Vec2)
    func viewportDragEnded(at p: Vec2, moved: Bool, clickCount: Int, modifiers: NSEvent.ModifierFlags)
    /// A click on empty canvas (no drag).
    func viewportClickedEmpty(modifiers: NSEvent.ModifierFlags)
    /// Marquee finished; `quad` is the dragged rectangle's corners projected onto the material plane.
    func viewportMarquee(_ quad: [Vec2], modifiers: NSEvent.ModifierFlags)
    func viewportMenu(at p: Vec2, tolerance: Double) -> NSMenu?
    /// Arrow keys, Escape, Delete. Return true if handled.
    func viewportKeyDown(_ event: NSEvent) -> Bool
    func viewportPerform(_ command: CanvasCommand)
    func viewportCanPerform(_ command: CanvasCommand) -> Bool
}

/// Mac-style direct manipulation of design shapes: click/shift-click selection, marquee, drag to move,
/// arrow-key nudging, cut/copy/paste/duplicate/delete, and a context menu.
@MainActor
final class CanvasController: ViewportInteractionDelegate {
    var project: Binding<Project>
    let workspace: Workspace
    /// Called to change the camera from the context menu.
    var setView: (ViewPreset) -> Void = { _ in }
    var fit: () -> Void = {}

    private var dragStart: Vec2?
    private var dragIDs: Set<UUID> = []
    private var downHit: UUID?

    static let pasteboardType = NSPasteboard.PasteboardType("com.nativecam.shapes")

    init(project: Binding<Project>, workspace: Workspace) {
        self.project = project
        self.workspace = workspace
    }

    private var p: Project { project.wrappedValue }
    private var selected: Set<UUID> { Set(workspace.selectedShapeIDs) }

    private func select(_ ids: Set<UUID>) {
        workspace.selection = Set(ids.map { SidebarItem.shape($0) })
    }

    // MARK: Mouse

    func viewportMouseDown(at point: Vec2, tolerance: Double, modifiers: NSEvent.ModifierFlags) -> Bool {
        guard let hit = workspace.hitTest(point, tolerance: tolerance, project: p) else { return false }
        let extend = modifiers.contains(.shift) || modifiers.contains(.command)
        if extend {
            var s = selected
            if s.contains(hit) { s.remove(hit) } else { s.insert(hit) }
            select(s)
            // Shift-click toggles; it doesn't start a move of a just-deselected shape.
            guard selected.contains(hit) else { return true }
        } else if !selected.contains(hit) {
            select([hit])
        }
        dragStart = point
        dragIDs = selected
        downHit = hit
        return true
    }

    func viewportDragMoved(to point: Vec2) {
        guard let start = dragStart, !dragIDs.isEmpty else { return }
        workspace.setDragPreview(dragIDs, offset: point - start, project: p)
    }

    func viewportDragEnded(at point: Vec2, moved: Bool, clickCount: Int, modifiers: NSEvent.ModifierFlags) {
        defer {
            dragStart = nil
            dragIDs = []
            downHit = nil
        }
        guard let start = dragStart else { return }
        if moved, !dragIDs.isEmpty {
            let delta = point - start
            workspace.setDragPreview([], offset: nil, project: p)
            translate(dragIDs, by: delta)
        } else {
            workspace.setDragPreview([], offset: nil, project: p)
            // Plain click on one of several selected shapes narrows the selection to it.
            let extend = modifiers.contains(.shift) || modifiers.contains(.command)
            if !extend, dragIDs.count > 1, let hit = downHit { select([hit]) }
        }
    }

    func viewportClickedEmpty(modifiers: NSEvent.ModifierFlags) {
        if !modifiers.contains(.shift) && !modifiers.contains(.command) { workspace.selection = [] }
    }

    func viewportMarquee(_ quad: [Vec2], modifiers: NSEvent.ModifierFlags) {
        guard quad.count == 4 else { return }
        let poly = Polyline(quad, closed: true)
        var ids = Set<UUID>()
        for shape in p.shapes {
            let b = workspace.outlines(shape).bounds
            guard !b.isEmpty else { continue }
            let corners = [b.min, Vec2(b.max.x, b.min.y), b.max, Vec2(b.min.x, b.max.y)]
            if corners.allSatisfy({ poly.contains($0) }) { ids.insert(shape.id) }
        }
        if modifiers.contains(.shift) || modifiers.contains(.command) { ids.formUnion(selected) }
        select(ids)
    }

    // MARK: Keyboard

    func viewportKeyDown(_ event: NSEvent) -> Bool {
        guard let key = event.specialKey else {
            if event.keyCode == 53 { // Escape
                workspace.selection = []
                return true
            }
            return false
        }
        let big = event.modifierFlags.contains(.shift)
        let step: Double = p.displayUnits == .inch ? (big ? 1.inch : 0.0625.inch) : (big ? 10 : 1)
        switch key {
        case .leftArrow: nudge(Vec2(-step, 0))
        case .rightArrow: nudge(Vec2(step, 0))
        case .upArrow: nudge(Vec2(0, step))
        case .downArrow: nudge(Vec2(0, -step))
        case .delete, .deleteForward, .backspace: viewportPerform(.delete)
        default: return false
        }
        return true
    }

    private func nudge(_ d: Vec2) {
        guard !selected.isEmpty else { NSSound.beep(); return }
        translate(selected, by: d)
    }

    private func translate(_ ids: Set<UUID>, by d: Vec2) {
        guard d.length > 1e-9 else { return }
        var proj = p
        for i in proj.shapes.indices where ids.contains(proj.shapes[i].id) { proj.shapes[i].position += d }
        project.wrappedValue = proj // one document change = one undo step
    }

    // MARK: Edit commands

    func viewportCanPerform(_ command: CanvasCommand) -> Bool {
        switch command {
        case .selectAll: return !p.shapes.isEmpty
        case .paste: return NSPasteboard.general.data(forType: Self.pasteboardType) != nil
        case .deselect: return !workspace.selection.isEmpty
        case .delete, .cut, .copy, .duplicate: return !selected.isEmpty
        }
    }

    func viewportPerform(_ command: CanvasCommand) {
        switch command {
        case .selectAll:
            select(Set(p.shapes.map(\.id)))
        case .deselect:
            workspace.selection = []
        case .delete:
            deleteSelected()
        case .copy:
            copySelected()
        case .cut:
            copySelected()
            deleteSelected()
        case .paste:
            paste()
        case .duplicate:
            insert(p.shapes.filter { selected.contains($0.id) }, offset: pasteOffset)
        }
    }

    private var pasteOffset: Vec2 { p.displayUnits == .inch ? Vec2(0.25.inch, -0.25.inch) : Vec2(5, -5) }

    private func deleteSelected() {
        let ids = selected
        guard !ids.isEmpty else { return }
        var proj = p
        proj.shapes.removeAll { ids.contains($0.id) }
        for i in proj.operations.indices { proj.operations[i].shapeIDs.removeAll { ids.contains($0) } }
        project.wrappedValue = proj
        workspace.selection = []
    }

    private func copySelected() {
        let shapes = p.shapes.filter { selected.contains($0.id) }
        guard !shapes.isEmpty, let data = try? JSONEncoder().encode(shapes) else { return }
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setData(data, forType: Self.pasteboardType)
        pb.setString(shapes.map(\.name).joined(separator: "\n"), forType: .string)
    }

    private func paste() {
        guard let data = NSPasteboard.general.data(forType: Self.pasteboardType),
              let shapes = try? JSONDecoder().decode([DesignShape].self, from: data), !shapes.isEmpty else { NSSound.beep(); return }
        // Offset only if the originals are still here (pasting into another document keeps positions).
        let existing = Set(p.shapes.map(\.id))
        insert(shapes, offset: shapes.contains { existing.contains($0.id) } ? pasteOffset : .zero)
    }

    private func insert(_ shapes: [DesignShape], offset: Vec2) {
        guard !shapes.isEmpty else { return }
        var proj = p
        var newIDs = Set<UUID>()
        for var s in shapes {
            s.id = UUID()
            s.position += offset
            proj.shapes.append(s)
            newIDs.insert(s.id)
        }
        project.wrappedValue = proj
        select(newIDs)
    }

    // MARK: Context menu

    func viewportMenu(at point: Vec2, tolerance: Double) -> NSMenu? {
        let menu = NSMenu()
        if let hit = workspace.hitTest(point, tolerance: tolerance, project: p) {
            // Mac convention: right-clicking an unselected item selects it first.
            if !selected.contains(hit) { select([hit]) }
            let toolpaths = NSMenuItem(title: "Add Toolpath", action: nil, keyEquivalent: "")
            let sub = NSMenu()
            let isModel = p.shape(id: hit)?.modelSpec != nil
            let kinds: [(String, AddOperationMenu.Kind)] = isModel
                ? [("3D Roughing", .rough3D), ("3D Finishing", .finish3D)]
                : [("Profile", .profile), ("Pocket", .pocket), ("Drill", .drill), ("V-Carve", .vcarve)]
            for (title, kind) in kinds {
                sub.addItem(ClosureMenuItem(title) { [weak self] in self?.addOperation(kind) })
            }
            toolpaths.submenu = sub
            menu.addItem(toolpaths)
            menu.addItem(.separator())
            menu.addItem(ClosureMenuItem("Cut") { [weak self] in self?.viewportPerform(.cut) })
            menu.addItem(ClosureMenuItem("Copy") { [weak self] in self?.viewportPerform(.copy) })
            menu.addItem(ClosureMenuItem("Duplicate") { [weak self] in self?.viewportPerform(.duplicate) })
            menu.addItem(ClosureMenuItem("Delete") { [weak self] in self?.viewportPerform(.delete) })
            menu.addItem(.separator())
            menu.addItem(ClosureMenuItem("Center on Material") { [weak self] in self?.centerSelection() })
        } else {
            let paste = ClosureMenuItem("Paste") { [weak self] in self?.viewportPerform(.paste) }
            paste.isEnabled = viewportCanPerform(.paste)
            menu.autoenablesItems = false
            menu.addItem(paste)
            let all = ClosureMenuItem("Select All") { [weak self] in self?.viewportPerform(.selectAll) }
            all.isEnabled = viewportCanPerform(.selectAll)
            menu.addItem(all)
        }
        menu.addItem(.separator())
        for preset in ViewPreset.allCases {
            menu.addItem(ClosureMenuItem("\(preset.label) View") { [weak self] in self?.setView(preset) })
        }
        menu.addItem(ClosureMenuItem("Zoom to Fit") { [weak self] in self?.fit() })
        return menu
    }

    private func addOperation(_ kind: AddOperationMenu.Kind) {
        let ids = workspace.selectedShapeIDs
        guard !ids.isEmpty else { return }
        let op = ShapeFactory.operation(kind, shapes: ids, project: p, library: ToolLibraryStore.shared.tools)
        project.wrappedValue.operations.append(op)
        workspace.selection = [.operation(op.id)]
    }

    private func centerSelection() {
        let ids = selected
        let b = p.shapes.filter { ids.contains($0.id) }.map { workspace.outlines($0).bounds }.reduce(Rect2.empty) { $0.union($1) }
        guard !b.isEmpty else { return }
        translate(ids, by: Vec2(p.stock.width / 2, p.stock.height / 2) - b.center)
    }
}

/// NSMenuItem that runs a closure.
final class ClosureMenuItem: NSMenuItem {
    private let handler: () -> Void

    init(_ title: String, handler: @escaping () -> Void) {
        self.handler = handler
        super.init(title: title, action: #selector(run), keyEquivalent: "")
        target = self
    }

    @available(*, unavailable)
    required init(coder: NSCoder) { fatalError() }

    @objc private func run() { handler() }
}
