import SwiftUI

// Mac D fix-up B1 — sheets that carry the app's objects into their content.
//
// On the Mac a sheet presented from inside the app's views does NOT inherit the app's `@Observable` objects from the
// view that presents it: ≡ › Settings crashed with "No Observable object of type CorpusStore found" (T: about half the
// time = whenever Settings came from the ≡ menu; AirPad › Settings… worked only because ContentView's own sheet hands
// the objects over itself). `.appSheet` / `.appFullScreenCover` read them where the sheet is declared and hand them to
// the content, so no sheet has to remember to. On iPhone and iPad they are plain `.sheet` / `.fullScreenCover`.

extension View {
    @ViewBuilder func appSheet<Sheet: View>(isPresented: Binding<Bool>, onDismiss: (() -> Void)? = nil,
                                            @ViewBuilder content: @escaping () -> Sheet) -> some View {
        #if targetEnvironment(macCatalyst)
        modifier(AppSheetPresented(isPresented: isPresented, onDismiss: onDismiss, fullScreen: false, sheet: content))
        #else
        sheet(isPresented: isPresented, onDismiss: onDismiss, content: content)
        #endif
    }

    @ViewBuilder func appSheet<Item: Identifiable, Sheet: View>(item: Binding<Item?>, onDismiss: (() -> Void)? = nil,
                                                                @ViewBuilder content: @escaping (Item) -> Sheet) -> some View {
        #if targetEnvironment(macCatalyst)
        modifier(AppSheetItem(item: item, onDismiss: onDismiss, fullScreen: false, sheet: content))
        #else
        sheet(item: item, onDismiss: onDismiss, content: content)
        #endif
    }

    @ViewBuilder func appFullScreenCover<Sheet: View>(isPresented: Binding<Bool>, onDismiss: (() -> Void)? = nil,
                                                      @ViewBuilder content: @escaping () -> Sheet) -> some View {
        #if targetEnvironment(macCatalyst)
        modifier(AppSheetPresented(isPresented: isPresented, onDismiss: onDismiss, fullScreen: true, sheet: content))
        #else
        fullScreenCover(isPresented: isPresented, onDismiss: onDismiss, content: content)
        #endif
    }

    @ViewBuilder func appFullScreenCover<Item: Identifiable, Sheet: View>(item: Binding<Item?>, onDismiss: (() -> Void)? = nil,
                                                                          @ViewBuilder content: @escaping (Item) -> Sheet) -> some View {
        #if targetEnvironment(macCatalyst)
        modifier(AppSheetItem(item: item, onDismiss: onDismiss, fullScreen: true, sheet: content))
        #else
        fullScreenCover(item: item, onDismiss: onDismiss, content: content)
        #endif
    }

    /// A popover that carries the app's objects too (the Mac pickers, `pickerPopover`).
    @ViewBuilder func appPopover<Sheet: View>(isPresented: Binding<Bool>, arrowEdge: Edge,
                                              @ViewBuilder content: @escaping () -> Sheet) -> some View {
        #if targetEnvironment(macCatalyst)
        modifier(AppPopoverPresented(isPresented: isPresented, arrowEdge: arrowEdge, sheet: content))
        #else
        popover(isPresented: isPresented, arrowEdge: arrowEdge, content: content)
        #endif
    }
}

/// The app's objects as the presenting view sees them (nil where it has none).
struct AppObjects {
    var store: CorpusStore?
    var router: AppRouter?
    var selection: SelectionService?
    var quarantine: QuarantineStore?
    var reorder: EntryReorderController?
}

#if targetEnvironment(macCatalyst)
/// Reads the app's objects from the environment of the view it's applied to.
private struct AppObjectsReader: DynamicProperty {
    @Environment(CorpusStore.self) private var store: CorpusStore?
    @Environment(AppRouter.self) private var router: AppRouter?
    @Environment(SelectionService.self) private var selection: SelectionService?
    @Environment(QuarantineStore.self) private var quarantine: QuarantineStore?
    @Environment(EntryReorderController.self) private var reorder: EntryReorderController?
    var objects: AppObjects { AppObjects(store: store, router: router, selection: selection, quarantine: quarantine, reorder: reorder) }
}

extension View {
    /// Hands the app's objects (and the app's body font) to this view's environment — on the Mac only.
    @ViewBuilder func carrying(_ o: AppObjects) -> some View {
        #if targetEnvironment(macCatalyst)
        self.carry(o.store).carry(o.router).carry(o.selection).carry(o.quarantine).carry(o.reorder).provideAppBodyFont()
        #else
        self
        #endif
    }

    @ViewBuilder fileprivate func carry<T: AnyObject & Observable>(_ object: T?) -> some View {
        if let object { environment(object) } else { self }
    }
}

private struct AppSheetPresented<Sheet: View>: ViewModifier {
    let isPresented: Binding<Bool>
    let onDismiss: (() -> Void)?
    let fullScreen: Bool
    let sheet: () -> Sheet
    private var reader = AppObjectsReader()

    func body(content: Content) -> some View {
        let objects = reader.objects
        if fullScreen {
            content.fullScreenCover(isPresented: isPresented, onDismiss: onDismiss) { sheet().carrying(objects) }
        } else {
            content.sheet(isPresented: isPresented, onDismiss: onDismiss) { sheet().carrying(objects) }
        }
    }
}

private struct AppSheetItem<Item: Identifiable, Sheet: View>: ViewModifier {
    let item: Binding<Item?>
    let onDismiss: (() -> Void)?
    let fullScreen: Bool
    let sheet: (Item) -> Sheet
    private var reader = AppObjectsReader()

    func body(content: Content) -> some View {
        let objects = reader.objects
        if fullScreen {
            content.fullScreenCover(item: item, onDismiss: onDismiss) { sheet($0).carrying(objects) }
        } else {
            content.sheet(item: item, onDismiss: onDismiss) { sheet($0).carrying(objects) }
        }
    }
}
private struct AppPopoverPresented<Sheet: View>: ViewModifier {
    let isPresented: Binding<Bool>
    let arrowEdge: Edge
    let sheet: () -> Sheet
    private var reader = AppObjectsReader()

    func body(content: Content) -> some View {
        let objects = reader.objects
        content.popover(isPresented: isPresented, arrowEdge: arrowEdge) { sheet().carrying(objects) }
    }
}
#endif
