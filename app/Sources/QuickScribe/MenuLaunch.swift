import Foundation

/// The launch order for the menu's model lists, in one place so it cannot
/// drift. The store must know where a finished answer goes, and must be
/// fetching, BEFORE the first menu is built. Built the other way round, that
/// first menu is drawn with nothing known and no request out, so it shows the
/// false "The server lists no speech models" until the answer lands, which on
/// a slow or stopped server is up to the refresh limit.
@MainActor
enum MenuLaunch {
    static func start(store: MenuModelStore,
                      onRefreshFinished: @escaping () -> Void,
                      buildMenu: () -> Void) {
        store.onRefreshFinished = onRefreshFinished
        store.refreshIfUseful()
        buildMenu()
    }
}
