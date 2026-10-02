import AppKit
import Darwin

autoreleasepool {
    signal(SIGPIPE, SIG_IGN)
    let application = NSApplication.shared
    application.setActivationPolicy(.regular)
    let delegate = ViewerApplication()
    application.delegate = delegate
    // NSApplication.delegate is weak; retain it until the application loop ends.
    withExtendedLifetime(delegate) { application.run() }
}
