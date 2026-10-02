import AppKit
import Darwin

autoreleasepool {
    signal(SIGPIPE, SIG_IGN)
    // Packaged OpenSSL must find its DES provider inside this app, not in
    // Homebrew's build-machine path. Set before any networking worker starts.
    // Development bundles without embedded providers keep the library default.
    if let modules = Bundle.main.privateFrameworksURL?.appendingPathComponent("ossl-modules", isDirectory: true),
       FileManager.default.fileExists(atPath: modules.path) {
        guard setenv("OPENSSL_MODULES", modules.path, 1) == 0 else {
            FileHandle.standardError.write(Data("Sharedesk: cannot configure bundled cryptography providers\n".utf8))
            exit(1)
        }
    }
    let application = NSApplication.shared
    application.setActivationPolicy(.regular)
    let delegate = ViewerApplication()
    application.delegate = delegate
    // NSApplication.delegate is weak; retain it until the application loop ends.
    withExtendedLifetime(delegate) { application.run() }
}
