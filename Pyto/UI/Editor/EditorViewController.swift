//
//  ViewController.swift
//  Pyto
//
//  Created by Emma Labbé on 9/8/18.
//  Copyright © 2018-2021 Emma Labbé. All rights reserved.
//

#if !WIDGET
import UIKit
import SourceEditor
import SavannaKit
import InputAssistant
import IntentsUI
import MarqueeLabel
import SwiftUI
import Highlightr
import AVKit
import GameKit
import LinkPresentation
#else
import Foundation
#endif

#if !WIDGET
func parseArgs(_ args: inout [String]) {
    ParseArgs(&args)
}
#endif

/// Obtains the current directory URL set for the given script.
///
/// - Parameters:
///     - scriptURL: The URL of the script.
///
/// - Returns: The current directory set for the given script.
func directory(for scriptURL: URL) -> URL {
    var isStale = false
    
    let defaultDir = scriptURL.deletingLastPathComponent()
    
    guard let data = try? scriptURL.extendedAttribute(forName: "currentDirectory") else {
        return defaultDir
    }
    
    guard let url = try? URL(resolvingBookmarkData: data, bookmarkDataIsStale: &isStale) else {
        return defaultDir
    }
    
    _ = url.startAccessingSecurityScopedResource()
    
    var isDir: ObjCBool = false
    guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir), isDir.boolValue else {
        return defaultDir
    }
    
    return url
}

#if !WIDGET
/// The View controller used to edit source code.
@objc class EditorViewController: UIViewController, InputAssistantViewDelegate, InputAssistantViewDataSource, UITextViewDelegate, UIDocumentPickerDelegate {
    
    @objc var shellID: String?
    
    private var lastShell: URL?
    
    /// Parses a string into a list of arguments.
    ///
    /// - Parameters:
    ///     - arguments: String of arguments.
    ///
    /// - Returns: A list of arguments to send to a program.
    @objc static func parseArguments(_ arguments: String) -> NSArray {
        var arguments_ = arguments.components(separatedBy: " ")
        parseArgs(&arguments_)
        return NSArray(array: arguments_)
    }
    
    /// Returns string used for indentation
    static var indentation: String {
        get {
            return UserDefaults.standard.string(forKey: "indentation") ?? "    "
        }
        
        set {
            UserDefaults.standard.set(newValue, forKey: "indentation")
            UserDefaults.standard.synchronize()
        }
    }
    
    /// The font used in the code editor and the console.
    static var font: UIFont {
        get {
            return UserDefaults.standard.font(forKey: "codeFont") ?? DefaultSourceCodeTheme().font
        }
        
        set {
            UserDefaults.standard.set(font: newValue, forKey: "codeFont")
        }
    }
    
    /// The text view containing the code.
    let textView: UITextView = {
        let textStorage = CodeAttributedString()
        textStorage.language = "Python"
        
        let textView = EditorTextView(frame: .zero, andTextStorage: textStorage) ?? EditorTextView(frame: .zero)
        textView.smartQuotesType = .no
        textView.smartDashesType = .no
        textView.autocorrectionType = .no
        textView.autocapitalizationType = .none
        textView.spellCheckingType = .no
        textView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        
        textView.inputAssistantItem.leadingBarButtonGroups = []
        textView.inputAssistantItem.trailingBarButtonGroups = []
        
        return textView
    }()
    
    /// The text storage of the text view.
    var textStorage: CodeAttributedString? {
        return textView.layoutManager.textStorage as? CodeAttributedString
    }
    
    /// The document to be edited.
    @objc var document: PyDocument? {
        didSet {
            isDocOpened = false
            
            loadViewIfNeeded()
            
            document?.editor = self
            
#if !SCREENSHOTS
            textView.contentTextView.isEditable = !(document?.documentState == .editingDisabled)
#else
            textView.contentTextView.isEditable = true
#endif
            
            NotificationCenter.default.addObserver(self, selector: #selector(stateChanged(_:)), name: UIDocument.stateChangedNotification, object: document)
            
            DispatchQueue.main.async { [weak self] in
                if !(self?.parent is REPLViewController) && !(self?.parent is RunModuleViewController) {
                    self?.view.window?.windowScene?.title = self?.document?.fileURL.lastPathComponent
                }
            }
            
            _ = document?.fileURL.startAccessingSecurityScopedResource()
            
            if #available(iOS 15.0, *) {
                (parent as? EditorSplitViewController)?.console?.pipTextView.pictureInPictureController?.invalidatePlaybackState()
            }
            
            definitionsNavVC = nil
            definitions = NSMutableArray()
            
            runFile = getRunFile()
            setBarItems()
        }
    }
    
    /// Returns `true` if the opened file is a sample.
    var isSample: Bool {
        guard document != nil else {
            return true
        }
        return !FileManager.default.isWritableFile(atPath: document!.fileURL.path)
    }
    
    /// A boolean indicating whether the opened script is a shortcut.
    var isShortcut = false
    
    /// The Input assistant view containing `suggestions`.
    var inputAssistant = InputAssistantView()
    
    /// A Navigation controller containing the documentation.
    var documentationNavigationController: UINavigationController?
    
    var isDocOpened = false
    
    private var areEditorButtonsSetup = false
    
    /// The line number where an error occurred. If this value is set at `viewDidAppear(_:)`, the error will be shown and the value will be reset to `nil`.
    var lineNumberError: Int?
    
    /// If set to true, the window will close after showing the save panel.
    var closeAfterSaving = false
    
    private func quote(_ arg: String) -> String {
        let result = Python.pythonShared?.perform(#selector(PythonRuntime.getString(_:)), with: """
        import shlex
        import base64
        
        string = base64.b64decode("\(arg.data(using: .utf8)?.base64EncodedString() ?? "")").decode("utf-8")
        
        s = shlex.quote(string)
        """)
        return (result?.takeUnretainedValue() as? String) ?? arg
    }
    
    /// Arguments passed to the script.
    var args: String {
        get {
            let key = "arguments\(document?.fileURL.resolvingSymlinksInPath().path.replacingOccurrences(of: "//", with: "/") ?? "")"
            if let str = UserDefaults.standard.string(forKey: key) {
                return str
            } else if let array = UserDefaults.standard.stringArray(forKey: key) {
                return array.map({ quote($0) }).joined(separator: " ")
            } else {
                return ""
            }
        }
        
        set {
            UserDefaults.standard.set(newValue, forKey: "arguments\(document?.fileURL.resolvingSymlinksInPath().path.replacingOccurrences(of: "//", with: "/") ?? "")")
        }
    }
    
    /// Directory in which the script will be ran.
    var currentDirectory: URL {
        get {
            if let url = document?.fileURL {
                return directory(for: url)
            } else {
                return FileBrowserViewController.localContainerURL
            }
        }
        
        set {
            guard newValue != self.document?.fileURL.deletingLastPathComponent() else {
                if (try? self.document?.fileURL.extendedAttribute(forName: "currentDirectory")) != nil {
                    do {
                        try self.document?.fileURL.removeExtendedAttribute(forName: "currentDirectory")
                    } catch {
                        print(error.localizedDescription)
                    }
                }
                return
            }
            
#if !SCREENSHOTS
            if let data = try? newValue.bookmarkData() {
                do {
                    try self.document?.fileURL.setExtendedAttribute(data: data, forName: "currentDirectory")
                } catch {
                    print(error.localizedDescription)
                }
            }
#endif
        }
    }
    
    /// Set to `true` before presenting to run the code.
    var shouldRun = false
    
    /// Handles state changes on a document..
    @objc func stateChanged(_ notification: Notification) {
#if !SCREENSHOTS
        textView.contentTextView.isEditable = !(document?.documentState == .editingDisabled)
#else
        textView.contentTextView.isEditable = true
#endif
        
        if document?.documentState.contains(.inConflict) == true {
            save { [weak self] (_) in
                
                guard let self = self else {
                    return
                }
                
                self.document?.checkForConflicts(onViewController: self, completion: { [weak self] in
                    
                    guard let self = self else {
                        return
                    }
                    
                    if let doc = self.document, let data = try? Data(contentsOf: doc.fileURL) {
                        try? doc.load(fromContents: data, ofType: "public.python-script")
                        
                        if doc.text != self.textView.text {
                            self.textView.text = doc.text
                        }
                        
                        self.updateSuggestions(force: true)
                    }
                })
            }
        }
    }
    
    private var parentNavigationItem: UINavigationItem? {
        return parent?.navigationItem
    }
    
    private var parentVC: UIViewController? {
        return parent
    }
    
    /// A navigation controller showing this editor on compact views.
    var compactNavigationController: UINavigationController?
    
    /// An intent for running the script.
    var runScriptIntent: RunScriptIntent {
        var args = self.args.components(separatedBy: " ")
        ParseArgs(&args)
        
        let intent = RunScriptIntent()
        do {
            var name = document!.fileURL.lastPathComponent
            if name == "__init__.py" || name == "__main__.py" {
                name = document!.fileURL.deletingLastPathComponent().lastPathComponent
            }
            
            intent.script = INFile(data: try self.document!.fileURL.bookmarkData(), filename: name, typeIdentifier: "public.python-script")
        } catch {
            print(error.localizedDescription)
        }
        intent.arguments = args
        
        return intent
    }
    
    @objc private var lastCodeFromCompletions: String?
    
    /// Returns the text of the text view from any thread.
    @objc var text: String {
        
        if Thread.current.isMainThread {
            return textView.text
        } else {
            let semaphore = DispatchSemaphore(value: 0)
            
            var value = ""
            
            DispatchQueue.main.async {
                value = self.text
                semaphore.signal()
            }
            
            semaphore.wait()
            
            return value
        }
    }
    
    /// Initialize with given document.
    ///
    /// - Parameters:
    ///     - document: The document to be edited.
    init(document: PyDocument) {
        super.init(nibName: nil, bundle: nil)
        self.document = document
        self.document?.editor = self
    }
    
    required init?(coder aDecoder: NSCoder) {
        super.init(coder: aDecoder)
    }
    
    // MARK: - Traceback
    
    /// The traceback accessible from the navigation bar.
    var traceback: Traceback? {
        didSet {
            DispatchQueue.main.async {
                self.setBarItems()
            }
        }
    }
    
    /// Shows `traceback`.
    @objc func showTraceback() {
        guard let traceback = traceback else {
            return
        }
        
        let excView = NavigationView {
            ExceptionView(traceback: traceback, editor: self)
        }.navigationViewStyle(.stack)
        let vc = UIHostingController(rootView: excView)
        vc.modalPresentationStyle = .formSheet
        if #available(iOS 15.0, *) {
            vc.sheetPresentationController?.detents = [.medium(), .large()]
            vc.sheetPresentationController?.prefersGrabberVisible = true
        }
        
        let console = (parent as? EditorSplitViewController)?.console
        if console?.movableTextField?.textField.isFirstResponder == true {
            console?.movableTextField?.textField.resignFirstResponder()
        }
        
        if textView.isFirstResponder {
            textView.resignFirstResponder()
        }
        
        present(vc, animated: true, completion: nil)
    }
    
    /**
     Shows a traceback.
     
     Format:
     {
     "exc_type": "ZeroDivisionError",
     "msg": "division by zero",
     "as_text": "Traceback (most recent call last):\n  File \"/iCloud//test/exc.py\", line 12, in <module>\n    main()\n  File \"/iCloud//test/exc.py\", line 9, in main\n    return 0/0\nZeroDivisionError: division by zero\n",
     "stack": [
     {
     "file_path": "/iCloud//test/exc.py",
     "lineno": 9,
     "line": "return 0/0",
     "name": "main",
     "index": 0
     "_id": "xxx",
     },
     {
     "file_path": "/iCloud//test/exc.py",
     "lineno": 12,
     "line": "main()",
     "name": "<module>",
     "index": 1
     "_id": "xxx",
     }
     ]
     }
     */
    @objc func showTraceback(_ json: String) {
        
        do {
            traceback = try JSONDecoder().decode(Traceback.self, from: json.data(using: .utf8) ?? Data())
            DispatchQueue.main.async { [weak self] in
                guard let self = self else {
                    return
                }
                
                guard let traceback = self.traceback else {
                    return
                }
                
                guard self.view.window != nil && (self.view.window?.windowScene?.activationState == .foregroundActive || self.view.window?.windowScene?.activationState == .foregroundInactive) else {
                    (self.parent as? EditorSplitViewController)?.console?.print(traceback.as_text)
                    return
                }
                
                self.showTraceback()
            }
        } catch {
            print(error.localizedDescription)
        }
    }
    
    // MARK: - Bar button items
    
    /// The Mac toolbar item for running the script.
    var runToolbarItem: NSObject?
    
    /// The button item that shows the menu.
    var ellipsisButtonItem: UIBarButtonItem!
    
    /// The bar button item for running script.
    var runBarButtonItem: UIBarButtonItem!
    
    /// The bar button item for stopping script.
    var stopBarButtonItem: UIBarButtonItem!
    
    /// Button for searching for text in the editor.
    var searchItem: UIBarButtonItem!
    
    /// Button for going back to scripts.
    var scriptsItem: UIBarButtonItem!
    
    /// Button for showing the linter.
    var linterItem: UIBarButtonItem!
    
    /// The button for seeing definitions.
    var definitionsItem: UIBarButtonItem!
    
    /// The button for toggling PIP.
    var pipItem: UIBarButtonItem!
    
    /// Show traceback.
    var showTracebackItem: UIBarButtonItem!
    
    /// Toggle terminal.
    var terminalItem: UIBarButtonItem!
    
    /// If set to `true`, the back button will always be displayed.
    var alwaysShowBackButton = false
    
    var recentsMenu: UIMenu?
    
    // MARK: - Theme
    
    private var lastCSS = ""
    
    /// Setups the View controller interface for given theme.
    ///
    /// - Parameters:
    ///     - theme: The theme to apply.
    func setup(theme: Theme) {
        
        guard view.window?.windowScene?.activationState != .background && view.window?.windowScene?.activationState != .unattached && view.window != nil else {
            return
        }
        
        textView.isHidden = false
        
        textView.contentTextView.inputAccessoryView = nil
        textView.font = EditorViewController.font.withSize(CGFloat(ThemeFontSize))
        textStorage?.highlightr.theme.codeFont = textView.font
        
        // SwiftUI
        parent?.parent?.parent?.view.backgroundColor = theme.sourceCodeTheme.backgroundColor
        
        view.backgroundColor = theme.sourceCodeTheme.backgroundColor
        parent?.view.backgroundColor = view.backgroundColor
        
        let firstChild = (parent as? EditorSplitViewController)?.firstChild
        let secondChild = (parent as? EditorSplitViewController)?.secondChild
        firstChild?.view.backgroundColor = view.backgroundColor
        secondChild?.view.backgroundColor = view.backgroundColor
        
        let highlightrTheme = HighlightrTheme(themeString: theme.css)
        highlightrTheme.setCodeFont(EditorViewController.font.withSize(CGFloat(ThemeFontSize)))
        highlightrTheme.themeBackgroundColor = theme.sourceCodeTheme.backgroundColor
        highlightrTheme.themeTextColor = theme.sourceCodeTheme.color(for: .plain)
        
        if lastCSS != theme.css {
            textStorage?.highlightr.theme = highlightrTheme
            textView.textColor = theme.sourceCodeTheme.color(for: .plain)
            textView.backgroundColor = theme.sourceCodeTheme.backgroundColor
        }
        lastCSS = theme.css
        
        if traitCollection.userInterfaceStyle == .dark {
            textView.contentTextView.keyboardAppearance = .dark
        } else {
            textView.contentTextView.keyboardAppearance = theme.keyboardAppearance
        }
        
        let lineNumberText = textView as? LineNumberTextView
        lineNumberText?.lineNumberTextColor = theme.sourceCodeTheme.color(for: .plain).withAlphaComponent(0.5)
        lineNumberText?.lineNumberBackgroundColor = theme.sourceCodeTheme.backgroundColor
        lineNumberText?.lineNumberFont = EditorViewController.font.withSize(CGFloat(ThemeFontSize))
        lineNumberText?.lineNumberBorderColor = .clear
        
        if parent?.superclass?.isSubclass(of: EditorSplitViewController.self) == false {
            (parent as? EditorSplitViewController)?.separatorColor = theme.sourceCodeTheme.color(for: .plain).withAlphaComponent(0.5)
        }
        
        textView.contentTextView.inputAccessoryView = nil
        
        inputAssistant = InputAssistantView()
        inputAssistant.delegate = self
        inputAssistant.dataSource = self
        inputAssistant.leadingActions = [InputAssistantAction(image: UIImage())]+[InputAssistantAction(image: UIImage(systemName: "arrow.forward.to.line") ?? UIImage(), target: self, action: #selector(insertTab))]
        if !(traitCollection.horizontalSizeClass == .regular && traitCollection.verticalSizeClass == .regular) {
            inputAssistant.attach(to: textView.contentTextView)
        }
        inputAssistant.trailingActions = [InputAssistantAction(image: EditorSplitViewController.downArrow, target: textView.contentTextView, action: #selector(textView.contentTextView.resignFirstResponder))]+[InputAssistantAction(image: UIImage())]
        
        textView.contentTextView.reloadInputViews()
    }
    
    /// Called when the user choosed a theme.
    @objc func themeDidChange(_ notification: Notification?) {
        setup(theme: ConsoleViewController.choosenTheme)
    }
    
    @objc func togglePIP() {
        (parent as? EditorSplitViewController)?.console?.togglePIP()
    }
    
    func setToggleTerminalItemTitle() {
        guard let console = (parent as? EditorSplitViewController)?.console else {
            return
        }
        
        guard let terminalItem = terminalItem else {
            return
        }
        
        if console.view.frame.height > 0 {
            terminalItem.title = NSLocalizedString("menuItems.hideTerminal", comment: "Menu item for showing the terminal")
            terminalItem.image = UIImage(systemName: "terminal.fill")
        } else {
            terminalItem.title = NSLocalizedString("menuItems.showTerminal", comment: "Menu item for hiding the terminal")
            terminalItem.image = UIImage(systemName: "terminal")
        }
    }
    
    @objc func toggleTerminal() {
        
        guard EditorSplitViewController.shouldShowConsoleAtBottom else {
            return
        }
        
        let splitVC = parent as? EditorSplitViewController
        guard let console = splitVC?.console else {
            return
        }
        
        if console.view.frame.height > 0 { // Show
            
            splitVC?.firstViewHeightRatioConstraint?.isActive = false
            let constraint = (splitVC?.firstViewHeightRatioConstraint?.isActive == true) ? splitVC?.firstViewHeightRatioConstraint : splitVC?.firstViewHeightConstraint
            
            previousConstraintValue = constraint?.constant
            constraint?.constant = parent?.view?.frame.height ?? 0
        } else if var previousConstraintValue = previousConstraintValue { // Hide
            
            if previousConstraintValue == view.window?.frame.height {
                previousConstraintValue = previousConstraintValue/2
            }
            
            let splitVC = parent as? EditorSplitViewController
            let constraint = (splitVC?.firstViewHeightRatioConstraint?.isActive == true) ? splitVC?.firstViewHeightRatioConstraint : splitVC?.firstViewHeightConstraint
            
            constraint?.constant = previousConstraintValue
            self.previousConstraintValue = nil
        }
    }
    
    func getRunFile() -> URL? {
        guard let url = document?.fileURL else {
            return nil
        }
        
        var dir = url.deletingLastPathComponent()
        var run = dir.appendingPathComponent(".run.py")
        while !FileManager.default.fileExists(atPath: run.path) {
            dir = dir.deletingLastPathComponent()
            run = run.appendingPathComponent(".run.py")
            
            if !FileManager.default.fileExists(atPath: dir.path) {
                break
            }
        }
        
        if FileManager.default.fileExists(atPath: run.path) {
            return run
        } else {
            return nil
        }
    }
    
    var runFile: URL?
    
    /// Sets bar items.
    func setBarItems() {
        
        guard !(parent is ScriptRunnerViewController) else {
            return
        }
        
        guard !(parent is PipInstallerViewController) else {
            return
        }
        
        guard (parent as? EditorSplitViewController)?.isConsoleShown == false else {
            return
        }
        
        guard document != nil else {
            return
        }
        
        if runFile == nil && document?.fileURL.pathExtension.lowercased() != "py" {
            runFile = getRunFile()
        }
        
#if targetEnvironment(simulator)
        let isPIPSupported = true
#else
        let isPIPSupported: Bool
        if #available(iOS 15.0, *), !isiOSAppOnMac {
            isPIPSupported = AVPictureInPictureController.isPictureInPictureSupported()
        } else {
            isPIPSupported = false
        }
#endif
        
        let unlockButtonItem = UIBarButtonItem(image: UIImage(systemName: "lock"), style: .plain, target: self, action: #selector(setCwd(_:)))
        
        if ellipsisButtonItem == nil {
            ellipsisButtonItem = UIBarButtonItem(title: nil, image: UIImage(systemName: "ellipsis.circle"), primaryAction: nil, menu: nil)
        }
        
        let pipController: AVPictureInPictureController?
        if #available(iOS 15.0, *) {
            pipController = (parent as? EditorSplitViewController)?.console?.pipTextView.pictureInPictureController
        } else {
            pipController = nil
        }
        
        makeDocsIfNeeded()
        
        ellipsisButtonItem.menu = UIMenu(title: "", image: nil, identifier: nil, options: [], children: [
            
            UIAction(title: NSLocalizedString("runAndSetArguments", comment: "Description for key command for running and setting arguments."), image: UIImage(systemName: "play"), identifier: nil, discoverabilityTitle: NSLocalizedString("runAndSetArguments", comment: "Description for key command for running and setting arguments."), attributes: [], state: .off, handler: { [weak self] _ in
                self?.setArgs(true)
            }),
            
            UIAction(title: NSLocalizedString("debugger", comment: "'Debugger'"), image: UIImage(systemName: "ant"), identifier: nil, discoverabilityTitle: NSLocalizedString("debugger", comment: "'Debugger'"), attributes: [], state: .off, handler: { [weak self] _ in
                self?.debug()
            }),
            
            UIAction(title: NSLocalizedString("help.documentation", comment: "'Documentation' button"), image: UIImage(systemName: "book"), identifier: nil, discoverabilityTitle: NSLocalizedString("help.documentation", comment: "'Documentation' button"), attributes: [], state: .off, handler: { [weak self] action in
                self?.showDocs(action)
            }),
            
            UIAction(title: NSLocalizedString("runtime", comment: "'Runtime' button on the editor"), image: UIImage(systemName: "gear"), identifier: nil, discoverabilityTitle: NSLocalizedString("runtime", comment: "'Runtime' button on the editor"), attributes: [], state: .off, handler: { [weak self] action in
                self?.showRuntimeSettings(action)
            })
            
        ] + (!isPIPSupported ? [] : [UIAction(title: (pipController?.isPictureInPictureActive == true) ? NSLocalizedString("pip.exit", comment: "'Exit PIP'") : NSLocalizedString("pip.enter", comment: "'Enter PIP'"), image: UIImage(systemName: "pip.enter"), identifier: nil, discoverabilityTitle: nil, attributes: [], state: .off, handler: { [weak self] _ in
            
            self?.togglePIP()
        })]) + [
            UIAction(title: NSLocalizedString("menuItems.share", comment: "The menu item to share a file"), image: UIImage(systemName: "square.and.arrow.up"), identifier: nil, discoverabilityTitle: NSLocalizedString("menuItems.share", comment: "The menu item to share a file"), attributes: [], state: .off, handler: { [weak self] _ in
                self?.share(self!.ellipsisButtonItem)
            })
        ])
        
        runBarButtonItem = UIBarButtonItem(image: UIImage(systemName: "play"), style: .plain, target: self, action: #selector(run))
        runBarButtonItem.title = NSLocalizedString("menuItems.run", comment: "The 'Run' menu item")
        stopBarButtonItem = UIBarButtonItem(image: UIImage(systemName: "stop.fill"), style: .plain, target: self, action: #selector(stop))
        stopBarButtonItem.title = NSLocalizedString("stop", comment: "Stop the execution of a script")
        
        if pipItem == nil {
            pipItem = UIBarButtonItem(image: UIImage(systemName: "pip.enter"), style: .plain, target: self, action: #selector(togglePIP))
            pipItem.title = NSLocalizedString("pip.enter", comment: "'Enter PIP'")
        }
        
        if showTracebackItem == nil {
            showTracebackItem = UIBarButtonItem(image: UIImage(systemName: "exclamationmark.triangle.fill"), style: .plain, target: self, action: NSSelectorFromString("showTraceback"))
            showTracebackItem.tintColor = .systemRed
        }
        
        let debugButton = UIButton(frame: CGRect(x: 0, y: 0, width: 30, height: 30))
        debugButton.addTarget(self, action: #selector(debug), for: .touchUpInside)
        
        let scriptsButton = UIButton(frame: CGRect(x: 0, y: 0, width: 30, height: 30))
        scriptsButton.setImage(EditorSplitViewController.gridImage, for: .normal)
        scriptsButton.addTarget(self, action: #selector(close), for: .touchUpInside)
        scriptsItem = UIBarButtonItem(customView: scriptsButton)
        
        let defintionsButton = UIButton(frame: CGRect(x: 0, y: 0, width: 30, height: 30))
        defintionsButton.setImage(UIImage(systemName: "list.dash"), for: .normal)
        defintionsButton.addTarget(self, action: #selector(showDefintions(_:)), for: .touchUpInside)
        defintionsButton.imageView?.preferredSymbolConfiguration = UIImage.SymbolConfiguration(font: UIFont.preferredFont(forTextStyle: .title2))
        definitionsItem = UIBarButtonItem(customView: defintionsButton)
        definitionsItem.title = NSLocalizedString("Definitions", comment: "")
        definitionsItem.isEnabled = (document?.fileURL.pathExtension.lowercased() == "py")
        
        let searchButton = UIButton(frame: CGRect(x: 0, y: 0, width: 30, height: 30))
        if #available(iOS 13.0, *) {
            searchButton.setImage(UIImage(systemName: "magnifyingglass"), for: .normal)
        } else {
            searchButton.setImage(UIImage(named: "Search"), for: .normal)
        }
        searchButton.addTarget(self, action: #selector(search), for: .touchUpInside)
        searchItem = UIBarButtonItem(customView: searchButton)
        searchItem.title = NSLocalizedString("find", comment: "'Find'")
        if #available(iOS 16.0, *) {
            searchItem.menuRepresentation = UIAction(title: NSLocalizedString("find", comment: "'Find'"), image: UIImage(systemName: "magnifyingglass"), handler: { [weak self] _ in
                self?.search()
            })
        }
        
        if !(parent is REPLViewController) && !(parent is RunModuleViewController) && !(parent is PipInstallerViewController), (parent as? EditorSplitViewController)?.isConsoleShown != true {
            
            let isScript = document?.fileURL.pathExtension.lowercased() == "py"
            if isScript || runFile != nil {
                
                let tracebackItems: [UIBarButtonItem]
                if #available(iOS 16.0, *) {
                    tracebackItems = []
                } else {
                    tracebackItems = [showTracebackItem!]
                }
                
                if let path = isScript ? document?.fileURL.path : runFile?.path, Python.shared.isScriptRunning(path) {
                    let runItems: [UIBarButtonItem]
                    if #available(iOS 16.0, *), traitCollection.horizontalSizeClass == .regular {
                        runItems = []
                    } else {
                        runItems = [stopBarButtonItem!]
                    }
                    
                    let more: [UIBarButtonItem]
                    if #available(iOS 16.0, *) {
                        more = []
                    } else {
                        more = [ellipsisButtonItem!]
                    }
                    
                    let items = runItems+((traceback != nil) ? tracebackItems : [])+(!FileManager.default.isReadableFile(atPath: document!.fileURL.deletingLastPathComponent().path) ? [unlockButtonItem] : [])+more
                    parentNavigationItem?.rightBarButtonItems = items
                } else {
                    let runItems: [UIBarButtonItem]
                    if #available(iOS 16.0, *) {
                        runItems = []
                    } else {
                        runItems = [runBarButtonItem]
                    }
                    
                    let more: [UIBarButtonItem]
                    if #available(iOS 16.0, *) {
                        more = []
                    } else {
                        more = [ellipsisButtonItem!]
                    }
                    
                    let items = runItems+((traceback != nil) ? tracebackItems : [])+(!FileManager.default.isReadableFile(atPath: document!.fileURL.deletingLastPathComponent().path) ? [unlockButtonItem] : [])+more
                    parentNavigationItem?.rightBarButtonItems = items
                }
                
                if #available(iOS 16.0, *) {
                } else if #available(iOS 15, *) {
                    parentNavigationItem?.leftBarButtonItems = [searchItem, definitionsItem]
                } else {
                    parentNavigationItem?.leftBarButtonItems = [definitionsItem]
                }
            } else {
                if #available(iOS 16.0, *) {
                } else if #available(iOS 15, *) {
                    parentNavigationItem?.leftBarButtonItems = [searchItem]
                } else {
                    parentNavigationItem?.leftBarButtonItems = []
                }
                
                if #available(iOS 16.0, *) {
                } else {
                    if document?.fileURL.pathExtension.lowercased() == "html" {
                        if let path = document?.fileURL.path, Python.shared.isScriptRunning(path) {
                            parentNavigationItem?.rightBarButtonItems = [
                                stopBarButtonItem
                            ]
                        } else {
                            parentNavigationItem?.rightBarButtonItems = [
                                runBarButtonItem
                            ]
                        }
                    } else {
                        parentNavigationItem?.rightBarButtonItems = []
                    }
                }
            }
        }
        
        if !(parent is REPLViewController) && !(parent is RunModuleViewController) && !(parent is PipInstallerViewController) {
            parent?.title = document?.fileURL.lastPathComponent
            parent?.parent?.title = document?.fileURL.lastPathComponent
        }
        
        if #available(iOS 16.0, *), let url = document?.fileURL, !(parent is REPLViewController) && !(parent is RunModuleViewController) && !(parent is PipInstallerViewController) {
            
            let props = UIDocumentProperties(url: url)
            
            props.activityViewControllerProvider = {
                UIActivityViewController(activityItems: [self.document!.fileURL], applicationActivities: nil)
            }
            props.dragItemsProvider = { session in
                if let provider = NSItemProvider(contentsOf: url) {
                    return [UIDragItem(itemProvider: provider)]
                } else {
                    return []
                }
            }
            
            var folderName = url.deletingLastPathComponent().lastPathComponent
            if url.deletingLastPathComponent() == FileBrowserViewController.iCloudContainerURL {
                folderName = "iCloud Drive"
            }
            
            parentNavigationItem?.renameDelegate = self
            parentNavigationItem?.documentProperties = props
            parentNavigationItem?.style = .editor
            parentNavigationItem?.titleMenuProvider = { elements in
                UIMenu(children: (FileManager.default.isReadableFile(atPath: url.deletingLastPathComponent().path) ? [UIAction(title: folderName, image: UIImage(systemName: "folder"), handler: { _ in
                    let browser = FileBrowserViewController()
                    browser.directory = url.deletingLastPathComponent()
                    let splitVC = self.splitViewController as? SidebarSplitViewController
                    
                    if splitVC?.isCollapsed == true {
                        self.navigationController?.pushViewController(browser, animated: true)
                    } else if
                        splitVC?.displayMode == .secondaryOnly {
                        splitVC?.show(.supplementary)
                        DispatchQueue.main.asyncAfter(deadline: .now()+0.5, execute: {
                            splitVC?.fileBrowserNavVC.pushViewController(browser, animated: true)
                        })
                    } else {
                        splitVC?.fileBrowserNavVC.pushViewController(browser, animated: true)
                    }
                })] : []) + [UIDeferredMenuElement.uncached({ [weak self] completion in
                    if let recents = self?.recentsMenu {
                        completion([recents])
                    } else {
                        completion([])
                    }
                })] + elements)
            }
            
            let isScript = (document?.fileURL.pathExtension.lowercased() == "py")
            
            let runItem = (Python.shared.isScriptRunning(isScript ? (document?.fileURL.path ?? "") : (runFile?.path ?? "")) ? stopBarButtonItem! : runBarButtonItem!)
            let debuggerItem = UIBarButtonItem(image: UIImage(systemName: "ant"), style: .plain, target: self, action: #selector(debug))
            debuggerItem.title = NSLocalizedString("debugger", comment: "'Debugger'")
            let snippetsItem = UIBarButtonItem(image: UIImage(systemName: "ellipsis.curlybraces"), style: .plain, target: self, action: #selector(showSnippets))
            snippetsItem.title = "Snippets"
            let docsItem = UIBarButtonItem(image: UIImage(systemName: "books.vertical"), style: .plain, target: self, action: #selector(showDocs(_:)))
            docsItem.title = NSLocalizedString("help.documentation", comment: "'Documentation' button")
            let runtimeItem = UIBarButtonItem(image: UIImage(systemName: "folder.badge.gearshape"), style: .plain, target: self, action: #selector(showRuntimeSettings(_:)))
            runtimeItem.title = NSLocalizedString("runtime", comment: "'Runtime' button on the editor")
            terminalItem = UIBarButtonItem(image: nil, style: .plain, target: self, action: #selector(toggleTerminal))
            setToggleTerminalItemTitle()
            
            recentsMenu = UIMenu(title: NSLocalizedString("projectsBrowser.recent", comment: "'Recent' & NEW"), image: UIImage(systemName: "clock"), identifier: nil, options: .displayInline, children: RecentDataSource.shared.recent.reversed().map({ url in
                
                let modificationDateString: String?
                do {
                    let attr = try FileManager.default.attributesOfItem(atPath: url.path)
                    guard let modificationDate = attr[FileAttributeKey.modificationDate] as? Date else {
                        throw NSError()
                    }
                    
                    let dateFormatter = DateFormatter()
                    dateFormatter.dateStyle = .short
                    dateFormatter.timeStyle = .medium
                    modificationDateString = dateFormatter.string(from: modificationDate)
                } catch {
                    modificationDateString = nil
                }
                
                return UIAction(title: url.lastPathComponent, subtitle: modificationDateString, image: SidebarViewController.image(for: url, forceMonochrome: true).image, attributes: url == self.document?.fileURL ? .disabled : [], handler: { [weak self] _ in
                    
                    (self?.splitViewController as? SidebarSplitViewController)?.sidebar?.open(url: url, reloadRecents: true, run: false, completion: nil)
                })
            }))
            
            if linterItem == nil {
                linterItem = UIBarButtonItem(image: UIImage(systemName: "exclamationmark.octagon"), style: .plain, target: self, action: #selector(showLinter))
                linterItem.title = "Linter"
            }
            
            runItem.isEnabled = isScript || runFile != nil
            debuggerItem.isEnabled = isScript
            linterItem.isEnabled = isScript || (["c", "cc", "cpp", "cxx", "m", "mm", "h", "hpp"].contains(document?.fileURL.pathExtension.lowercased() ?? ""))
            runtimeItem.isEnabled = isScript
            
            parentNavigationItem?.customizationIdentifier = "editorToolbar"
            parentNavigationItem?.leadingItemGroups = [
                .fixedGroup(items: ((traceback != nil) ? [showTracebackItem!] : [])+(!FileManager.default.isReadableFile(atPath: document!.fileURL.deletingLastPathComponent().path) ? [unlockButtonItem] : []) + ((splitViewController as? SidebarSplitViewController)?.sidebar?.view.window == nil ? [] : []))
            ]
            
            parentNavigationItem?.centerItemGroups = ((traitCollection.horizontalSizeClass == .compact ? [] : [runItem.creatingMovableGroup(customizationIdentifier: "run")])) + [
                debuggerItem.creatingOptionalGroup(customizationIdentifier: "debugger", isInDefaultCustomization: true),
                runtimeItem.creatingOptionalGroup(customizationIdentifier: "runtime", isInDefaultCustomization: true),
                linterItem.creatingOptionalGroup(customizationIdentifier: "linter", isInDefaultCustomization: true),
                snippetsItem.creatingOptionalGroup(customizationIdentifier: "snippets", isInDefaultCustomization: true),
                searchItem.creatingOptionalGroup(customizationIdentifier: "find", isInDefaultCustomization: true),
                docsItem.creatingOptionalGroup(customizationIdentifier: "docs", isInDefaultCustomization: true),
                definitionsItem.creatingOptionalGroup(customizationIdentifier: "definitions", isInDefaultCustomization: true),
            ]
            
            for group in parentNavigationItem?.centerItemGroups ?? [] {
                group.alwaysAvailable = true
            }
            
            if traitCollection.horizontalSizeClass == .compact {
                parentNavigationItem?.trailingItemGroups = [
                    runItem.creatingFixedGroup(),
                    UIBarButtonItemGroup.fixedGroup(items: [
                        UIBarButtonItem(title: nil, image: UIImage(systemName: "chevron.down"), menu: UIMenu(title: "Terminal", options: .displayInline, children: [
                            
                            UIAction(title: terminalItem.title ?? "", image: terminalItem.image, handler: { [weak self] _ in
                                self?.toggleTerminal()
                            }),
                            
                            UIAction(title: pipItem.title ?? "", image: pipItem.image, handler: { [weak self] _ in
                                self?.togglePIP()
                            }),
                        ]))
                    ])
                ]
            } else {
                parentNavigationItem?.trailingItemGroups = [
                    UIBarButtonItemGroup.fixedGroup(representativeItem: UIBarButtonItem(title: nil, image: UIImage(systemName: "chevron.forward"), target: nil, action: nil), items: [
                        terminalItem, pipItem
                    ])
                ]
            }
        }
        
        NotificationCenter.default.post(name: Self.didUpdateBarItemsNotificationName, object: nil)
    }
    
    // MARK: - View controller
    
    deinit {
        NotificationCenter.default.removeObserver(self)
    }
    
    override func responds(to aSelector: Selector!) -> Bool {
        if aSelector == #selector(toggleCompletionsView(_:)) {
            return textView.isFirstResponder && completions.count > 0
        } else {
            return super.responds(to: aSelector)
        }
    }
    
    override func present(_ viewControllerToPresent: UIViewController, animated flag: Bool, completion: (() -> Void)? = nil) {
        textView.resignFirstResponder()
        super.present(viewControllerToPresent, animated: flag, completion: completion)
    }
    
    override func viewDidLoad() {
        super.viewDidLoad()
        
        if shellID == nil {
            shellID = UUID().uuidString
        }
        
        completionsHostingController = UIHostingController(rootView: CompletionsView(manager: codeCompletionManager))
        completionsHostingController.view.isHidden = true
        
        codeCompletionManager.editor = self
        codeCompletionManager.didSelectSuggestion = { [weak self] index in
            self?.inputAssistantView(self!.inputAssistant, didSelectSuggestionAtIndex: index)
        }
        
        edgesForExtendedLayout = []
        
        NotificationCenter.default.addObserver(self, selector: #selector(themeDidChange(_:)), name: ThemeDidChangeNotification, object: nil)
        NotificationCenter.default.addObserver(forName: UIApplication.willResignActiveNotification, object: nil, queue: nil) { [weak self] (notif) in
            self?.textView.resignFirstResponder()
        }
        NotificationCenter.default.addObserver(forName: UIApplication.didBecomeActiveNotification, object: nil, queue: nil) { [weak self] (notif) in
            self?.themeDidChange(notif)
        }
        
        if #available(iOS 13.0, *) {
            view.backgroundColor = .systemBackground
        }
        
        view.addSubview(textView)
        textView.delegate = self
        textView.isHidden = true
        
        textView.addSubview(completionsHostingController.view)
        
        if #available(iOS 16.0, *) {
            textView.isFindInteractionEnabled = true
        }
        
        NoSuggestionsLabel = {
            let label = MarqueeLabel(frame: .zero, rate: 100, fadeLength: 1)
            return label
        }
        inputAssistant.dataSource = self
        inputAssistant.delegate = self
        
        if document?.fileURL == URL(fileURLWithPath: NSTemporaryDirectory()+"/Temporary") {
            title = nil
        }
        
        setBarItems()
        
        NotificationCenter.default.addObserver(self, selector: #selector(keyboardDidShow), name: UIResponder.keyboardDidShowNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(keyboardDidShow), name: UIResponder.keyboardDidChangeFrameNotification, object: nil)
        
        NotificationCenter.default.addObserver(self, selector: #selector(keyboardWillHide), name: UIResponder.keyboardWillHideNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(keyboardWillShow), name: UIResponder.keyboardWillShowNotification, object: nil)
        
#if !SCREENSHOTS
        textView.contentTextView.isEditable = !isSample
#else
        textView.contentTextView.isEditable = true
#endif
    }
    
    override func traitCollectionDidChange(_ previousTraitCollection: UITraitCollection?) {
        super.traitCollectionDidChange(previousTraitCollection)
        
        guard view.window?.windowScene?.activationState != .background else {
            return
        }
        
        themeDidChange(nil)
    }
    
    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        
        setup(theme: ConsoleViewController.choosenTheme)
        
        func openDoc() {
            guard let doc = self.document else {
                return
            }
            
            let path = doc.fileURL.path
            
            switch document?.fileURL.pathExtension.lowercased() ?? "" {
            case "py", "pyi":
                (textView.textStorage as? CodeAttributedString)?.language = "python"
                codeCompletionManager.language = .python
            case "pyx", "pxd", "pxi":
                (textView.textStorage as? CodeAttributedString)?.language = "cython"
                codeCompletionManager.language = .cython
            case "html":
                (textView.textStorage as? CodeAttributedString)?.language = "html"
            case "c", "h":
                (textView.textStorage as? CodeAttributedString)?.language = "c"
                codeCompletionManager.language = .c
            case "cpp", "cxx", "cc", "hpp":
                (textView.textStorage as? CodeAttributedString)?.language = "c++"
                codeCompletionManager.language = .cpp
            case "m", "mm":
                (textView.textStorage as? CodeAttributedString)?.language = "objc"
                codeCompletionManager.language = .objc
            case "md":
                (textView.textStorage as? CodeAttributedString)?.language = "plaintext"
            default:
                (textView.textStorage as? CodeAttributedString)?.language = document?.fileURL.pathExtension.lowercased()
            }
            
            self.textView.text = document?.text ?? ""
            
#if !SCREENSHOTS
            if !FileManager.default.isWritableFile(atPath: doc.fileURL.path) {
                self.textView.contentTextView.isEditable = false
                self.textView.contentTextView.inputAccessoryView = nil
            }
#endif
            
            if doc.fileURL.path == Bundle.main.path(forResource: "installer", ofType: "py") && (!(parent is REPLViewController) && !(parent is RunModuleViewController) && !(parent is PipInstallerViewController)) {
                self.parentNavigationItem?.leftBarButtonItems = []
                if Python.shared.isScriptRunning(path) {
                    self.parentNavigationItem?.rightBarButtonItems = [self.stopBarButtonItem]
                } else {
                    self.parentNavigationItem?.rightBarButtonItems = [self.runBarButtonItem]
                }
            }
        }
        
        if !isDocOpened {
            
            parent?.addChild(completionsHostingController)
            parent?.view.addSubview(completionsHostingController.view)
            
            isDocOpened = true
            
            let console = (parent as? EditorSplitViewController)?.console
            
            for child in console?.children ?? [] {
                if child is PytoUIPreviewViewController {
                    child.view.removeFromSuperview()
                    child.removeFromParent()
                }
            }
            
            if document?.fileURL.pathExtension == "pytoui" {
                let previewVC = PytoUIPreviewViewController()
                previewVC.view.frame = console?.view.frame ?? .zero
                previewVC.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
                console?.addChild(previewVC)
                DispatchQueue.main.async {
                    console?.view.addSubview(previewVC.view)
                }
                
                console?.webView.isHidden = true
                console?.movableTextField?.toolbar.isHidden = true
                console?.movableTextField?.textField.isHidden = true
            } else {
                console?.webView.isHidden = false
                console?.movableTextField?.toolbar.isHidden = false
                console?.movableTextField?.textField.isHidden = false
            }
            
            if document?.hasBeenOpened != true {
                document?.open(completionHandler: { (_) in
                    openDoc()
                })
            } else {
                openDoc()
            }
        }
        
        if shouldRun, let path = document?.fileURL.path {
            shouldRun = false
            
            if Python.shared.isScriptRunning(path) {
                stop()
            }
            
            if Python.shared.isScriptRunning(path) || !Python.shared.isSetup {
                _ = Timer.scheduledTimer(withTimeInterval: 1, repeats: true, block: { [weak self] (timer) in
                    if !Python.shared.isScriptRunning(path) && Python.shared.isSetup {
                        timer.invalidate()
                        timer.invalidate()
                        self?.run()
                    }
                })
            } else {
                self.run()
            }
        }
        
        setBarItems()
    }
    
    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        
        DispatchQueue.main.asyncAfter(deadline: .now()+0.2) { [weak self] in
            self?.updateSuggestions(force: true)
            
            self?.setup(theme: ConsoleViewController.choosenTheme)
        }
        
        textView.frame = view.safeAreaLayoutGuide.layoutFrame
        
        if lastShell != document?.fileURL {
            lastShell = document?.fileURL
            runScript(debug: false, shellOnly: true)
        }
    }
    
    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        
        save()
    }
    
    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        
        if let parent = parent {
            compactNavigationController?.setViewControllers([parent], animated: true)
        }
    }
    
    override func viewWillTransition(to size: CGSize, with coordinator: UIViewControllerTransitionCoordinator) {
        super.viewWillTransition(to: size, with: coordinator)
        
        guard view != nil else {
            return
        }
        
        self.setup(theme: ConsoleViewController.choosenTheme)
    }
    
#if !Xcode11
    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        
        setBarItems()
        
        if !completionsHostingController.view.isHidden {
            placeCompletionsView()
        }
    }
#endif
    
    override var canBecomeFirstResponder: Bool {
        return true
    }
    
    override func canPerformAction(_ action: Selector, withSender sender: Any?) -> Bool {
        if action == #selector(unindent) {
            return isIndented && textView.isFirstResponder
        } else if action == #selector(search) || action == #selector(find(_:)) {
            if #available(iOS 15.0, *) {
                return true
            } else {
                return false
            }
        } else {
            return super.canPerformAction(action, withSender: sender)
        }
    }
    
    private var isIndented: Bool {
        var indented = false
        if let range = textView.contentTextView.selectedTextRange {
            for line in textView.contentTextView.text(in: range)?.components(separatedBy: "\n") ?? [] {
                if line.hasPrefix(EditorViewController.indentation) {
                    indented = true
                    break
                }
            }
        }
        if let line = textView.contentTextView.currentLine, line.hasPrefix(EditorViewController.indentation) {
            indented = true
        }
        
        return indented
    }
    
    override var keyCommands: [UIKeyCommand]? {
        if textView.contentTextView.isFirstResponder {
            var commands = [
                UIKeyCommand(input: UIKeyCommand.inputEscape, modifierFlags: [], action: #selector(toggleCompletionsView(_:)), discoverabilityTitle: completionsHostingController?.view.isHidden == false ? NSLocalizedString("menuItems.showCompletions", comment: "Menu item for showing completions") : NSLocalizedString("menuItems.hideCompletions", comment: "Menu item for hiding completions")),
            ]

            if let terminalItem = terminalItem {
                commands.append(UIKeyCommand(input: "t", modifierFlags: [.alternate, .command], action: #selector(toggleTerminal), discoverabilityTitle: terminalItem.title ?? ""))
            }
            
            if #available(iOS 15.0, *) {
            } else {
                commands.append(contentsOf: [
                    UIKeyCommand.command(input: "c", modifierFlags: [.command, .shift], action: #selector(toggleComment), discoverabilityTitle: NSLocalizedString("menuItems.toggleComment", comment: "The 'Toggle Comment' menu item")),
                    UIKeyCommand.command(input: "\t", modifierFlags: [.alternate], action: #selector(unindent), discoverabilityTitle: NSLocalizedString("unindent", comment: "'Unindent' key command"))
                ])
            }
            
            if numberOfSuggestionsInInputAssistantView() != 0 && completionsHostingController.view.isHidden {
                commands.append(UIKeyCommand.command(input: "\t", modifierFlags: [], action: #selector(nextSuggestion), discoverabilityTitle: NSLocalizedString("nextSuggestion", comment: "Title for command for selecting next suggestion")))
            }
            
            if completionsHostingController.view?.isHidden == false {
                commands.append(UIKeyCommand.command(input: UIKeyCommand.inputEscape, modifierFlags: [], action: #selector(hideSuggestions), discoverabilityTitle: NSLocalizedString("menuItems.hideSuggestions", comment: "The 'Hide suggestions' menu item")))
            }
                        
            return commands
        } else {
            return []
        }
    }
    
    // MARK: - Searching
    
    var searchVC: UIViewController!
    
    /// Searches for text in code.
    @objc func search() {
        
        guard #available(iOS 15.0, *) else {
            return
        }
        
        if #available(iOS 16.0, *) {
            if !textView.isFirstResponder {
                textView.becomeFirstResponder()
                DispatchQueue.main.asyncAfter(deadline: .now()+0.5) {
                    self.textView.findInteraction?.presentFindNavigator(showingReplace: true)
                }
            } else {
                textView.findInteraction?.presentFindNavigator(showingReplace: true)
            }
        } else {
            if searchVC == nil {
                searchVC = UIHostingController(rootView: TextViewSearch(textView: textView))
                searchVC.modalPresentationStyle = .pageSheet
            }
            
            if let presentationController = searchVC.presentationController as? UISheetPresentationController {
                presentationController.detents = [.medium(), .large()]
                presentationController.prefersGrabberVisible = true
            }
            
            present(searchVC, animated: true, completion: nil)
        }
    }
    
    @objc override func find(_ sender: Any?) {
        search()
    }
    
    // MARK: - Actions
    
    private var previousSelectedRange: NSRange?
    
    private var previousSelectedLine: String?
    
    @available(iOS 15.0, *)
    @objc func showSnippets() {
        previousSelectedRange = textView.selectedRange
        previousSelectedLine = textView.currentLine
        let snippetsView = SnippetsView(language: (textView.textStorage as? CodeAttributedString)?.language ?? "python", selectionHandler: { [weak self] codeString in
            
            var codeLines = [String]()
            
            if let range = self?.previousSelectedRange {
                let line = self?.previousSelectedLine ?? ""
                var indentation = ""
                for char in line {
                    let charString = String(char)
                    if charString != " " && charString == "\t" {
                        break
                    }
                    indentation += charString
                }
                
                var firstLine = true
                for codeLine in codeString.components(separatedBy: "\n") {
                    guard !firstLine else {
                        firstLine = false
                        codeLines.append(codeLine)
                        continue
                    }
                    
                    codeLines.append(indentation+codeLine)
                }
                
                let _code = self!.textView.text as NSString
                self?.textView.text = _code.replacingCharacters(in: range, with: codeLines.joined(separator: "\n"))
                self?.dismiss(animated: true) {
                    self?.textView.becomeFirstResponder()
                    self?.textView.selectedRange = NSRange(location: range.location, length: (codeLines.joined(separator: "\n") as NSString).length)
                }
            } else {
                
            }
        })
        
        present(UIHostingController(rootView: snippetsView), animated: true)
    }
    
    private var definitionsNavVC: UINavigationController?
    
    @available(iOS 15.0, *)
    fileprivate struct LinterView: SwiftUI.View {
        
        class WarningsHolder: ObservableObject {
            
            var warnings = [Linter.Warning]() {
                didSet {
                    objectWillChange.send()
                }
            }
        }
        
        @ObservedObject var warningsHolder: WarningsHolder
        
        var fileURL: URL
        
        var editor: EditorViewController
        
        var body: some SwiftUI.View {
            NavigationView {
                VStack {
                    if warningsHolder.warnings.first?.type == "linterloading" {
                        ProgressView().progressViewStyle(CircularProgressViewStyle())
                    } else if warningsHolder.warnings.count > 0 {
                        List {
                            Linter(editor: editor, fileURL: fileURL, code: editor.textView.text, warnings: warningsHolder.warnings, showCode: true, language: fileURL.pathExtension.lowercased() == "py" ? "python" : "objc")
                        }
                    } else {
                        Spacer()
                        Text("No errors or warnings").foregroundColor(.secondary)
                        Spacer()
                    }
                }
                    .navigationTitle("Linter")
                    .toolbar {
                        Button {
                            editor.dismiss(animated: true)
                        } label: {
                            Text("Done").bold()
                        }
                    }
                    .navigationBarHidden(editor.traitCollection.horizontalSizeClass == .regular)
            }.navigationViewStyle(.stack)
        }
    }
    
    var warningsHolder: Any?
    
    var linterVC: UIViewController?
    
    @objc func showLinter() {
        
        guard #available(iOS 15.0, *), let fileURL = document?.fileURL else {
            return
        }
        
        if warningsHolder == nil {
            warningsHolder = LinterView.WarningsHolder()
        }
        
        lint()
        
        let linter = LinterView(warningsHolder: warningsHolder as! LinterView.WarningsHolder, fileURL: fileURL, editor: self)
        
        linterVC = UIHostingController(rootView: linter)
    }
    
    /// Shows function definitions.
    @objc func showDefintions(_ sender: Any) {
        var navVC: UINavigationController! = definitionsNavVC
        
        updateSuggestions(getDefinitions: true)
        
        if navVC == nil {
            let view = DefinitionsView(defintions: definitionsList, handler: { (def) in
                navVC.dismiss(animated: true) {
                    
                    var lines = [NSRange]()
                    
                    let textView = self.textView.contentTextView
                    let text = NSString(string: textView.text)
                    text.enumerateSubstrings(in: text.range(of: text as String), options: .byLines) { (_, range, _, _) in
                        lines.append(range)
                    }
                    
                    if lines.indices.contains(def.line-1), textView.contentSize.height > textView.frame.height {
                        let substringRange = lines[def.line-1]
                        let glyphRange = textView.layoutManager.glyphRange(forCharacterRange: substringRange, actualCharacterRange: nil)
                        let rect = textView.layoutManager.boundingRect(forGlyphRange: glyphRange, in: textView.textContainer)
                        let topTextInset = textView.textContainerInset.top
                        let contentOffset = CGPoint(x: 0, y: topTextInset + rect.origin.y)
                        if textView.contentSize.height-contentOffset.y > textView.frame.height {
                            textView.setContentOffset(contentOffset, animated: true)
                        } else {
                            textView.scrollToBottom()
                        }
                    }
                    
                    if lines.indices.contains(def.line-1) {
                        textView.becomeFirstResponder()
                        textView.selectedRange = lines[def.line-1]
                    }
                }
            }) {
                navVC.dismiss(animated: true, completion: nil)
            }
            
            navVC = UINavigationController(rootViewController: UIHostingController(rootView: view))
            navVC.navigationBar.prefersLargeTitles = true
            navVC.modalPresentationStyle = .popover
        }
        
        navVC.popoverPresentationController?.barButtonItem = definitionsItem
        definitionsNavVC = navVC
        
        navVC.isNavigationBarHidden = traitCollection.horizontalSizeClass == .regular
        navVC.viewControllers.first?.title = document?.fileURL.lastPathComponent
        
        present(navVC, animated: true, completion: nil)
    }
    
    /// Shares the current script.
    @objc func share(_ sender: UIBarButtonItem) {
        let activityVC = UIActivityViewController(activityItems: [document?.fileURL as Any], applicationActivities: nil)
        activityVC.popoverPresentationController?.barButtonItem = sender
        present(activityVC, animated: true, completion: nil)
    }
    
    /// Opens an alert for setting arguments passed to the script.
    ///
    /// - Parameters:
    ///     - sender: The sender object. If called programatically with `sender` set to `true`, will run code after setting arguments.
    @objc func setArgs(_ sender: Any) {
        
        let alert = UIAlertController(title: NSLocalizedString("argumentsAlert.title", comment: "Title of the alert for setting arguments"), message: NSLocalizedString("argumentsAlert.message", comment: "Message of the alert for setting arguments"), preferredStyle: .alert)
        
        var textField: UITextField?
        
        alert.addTextField { (textField_) in
            textField = textField_
            textField_.text = self.args
        }
        
        if (sender as? Bool) == true {
            alert.addAction(UIAlertAction(title: NSLocalizedString("menuItems.run", comment: "The 'Run' menu item"), style: .default, handler: { _ in
                
                if let text = textField?.text {
                    self.args = text
                }
                
                self.run()
                
            }))
        } else {
            alert.addAction(UIAlertAction(title: NSLocalizedString("ok", comment: "'Ok' button"), style: .default, handler: { _ in
                
                if let text = textField?.text {
                    self.args = text
                }
                
            }))
        }
        
        alert.addAction(UIAlertAction(title: NSLocalizedString("cancel", comment: "'Cancel' button"), style: .cancel, handler: nil))
        
        present(alert, animated: true, completion: nil)
    }
    
    /// Sets current directory.
    @objc func setCwd(_ sender: Any) {
        
        let picker = UIDocumentPickerViewController(forOpeningContentTypes: [.folder])
        picker.delegate = self
        if #available(iOS 13.0, *) {
            picker.directoryURL = self.currentDirectory
        } else {
            picker.allowsMultipleSelection = true
        }
        self.present(picker, animated: true, completion: nil)
    }
    
    /// Stops the current running script.
    @objc func stop() {
        
        guard let path = document?.fileURL.pathExtension.lowercased() == "py" ? document?.fileURL.path : runFile?.path else {
            return
        }
        
        for console in ConsoleViewController.visibles {
            func stop_() {
                Python.shared.stop(script: path)
            }
            
            if console.presentedViewController != nil {
                console.dismiss(animated: true) {
                    stop_()
                }
            } else {
                stop_()
            }
        }
    }
    
    /// Debugs script.
    @objc func debug() {
        save { [weak self] _ in
            guard let self = self else {
                return
            }
            
            self.showDebugger(filePath: self.lastBreakpointFilePath, lineno: self.lastBreakpointLineno, tracebackJSON: self.lastTracebackJSON, id: self.lastBreakpointID, replID: self.replID)
        }
    }
    
    private class DebuggerHostingController: UIHostingController<AnyView> {}
    
    static let didTriggerBreakpointNotificationName = Notification.Name("DidTriggerBreakpointNotification")
    
    static let didUpdateBarItemsNotificationName = Notification.Name("DidUpdateBarItemsNotification")
    
    private var lastBreakpointFilePath: String?
    
    private var lastBreakpointLineno: Int?
    
    private var lastBreakpointID: String?
    
    private var lastTracebackJSON: String?
    
    func showDebugger(filePath: String?, lineno: Int?, tracebackJSON: String?, id: String?, replID: String?) {
        let vc: DebuggerHostingController
        if #available(iOS 15.0, *) {
                        
            let runningBreakpoint: Breakpoint?
            if let filePath = filePath, let lineno = lineno, let json = tracebackJSON {
                lastBreakpointFilePath = filePath
                lastBreakpointLineno = lineno
                lastTracebackJSON = json
                runningBreakpoint = try? Breakpoint(url: URL(fileURLWithPath: filePath), lineno: lineno)
            } else {
                runningBreakpoint = nil
            }
            
            guard !(presentedViewController is DebuggerHostingController) else {
                NotificationCenter.default.post(name: Self.didTriggerBreakpointNotificationName, object: runningBreakpoint, userInfo: ["id": id ?? "", "traceback": tracebackJSON ?? ""])
                return
            }
            
            vc = DebuggerHostingController(rootView: AnyView(BreakpointsView(fileURL: document!.fileURL, id: id, replID: replID, run: {
                self.runScript(debug: true)
            }, runningBreakpoint: runningBreakpoint, tracebackJSON: tracebackJSON).environment(\.editor, self)))
        } else {
            vc = DebuggerHostingController(rootView: AnyView(Text("The debugger requires iOS / iPadOS 15+.")))
        }
        
        if #available(iOS 15.0, *) {
            vc.sheetPresentationController?.prefersGrabberVisible = true
        }
        present(vc, animated: true, completion: nil)
    }
    
    /// Runs script.
    @objc func run() {
        
        textStorage?.removeAttribute(.backgroundColor, range: _NSRange(location: 0, length: NSString(string: textView.text).length))
        
        if textView.contentTextView.isFirstResponder {
            textView.contentTextView.resignFirstResponder()
            
            DispatchQueue.main.asyncAfter(deadline: .now()+0.5) { [weak self] in
                self?.runScript(debug: false)
            }
        } else {
            runScript(debug: false)
        }
    }
    
    weak var parentPipInstaller: EditorSplitViewController?
    
    /// Run the script represented by `document`.
    ///
    /// - Parameters:
    ///     - debug: Set to `true` for debugging with `pdb`.
    ///     - shellOnly: Set to `true` for running only a shell.
    func runScript(debug: Bool, shellOnly: Bool = false) {
        
        let isScript = document?.fileURL.pathExtension.lowercased() == "py" || document?.fileURL.pathExtension.lowercased() == "html" || shellOnly
        
        guard isScript || runFile != nil else {
            return
        }
        
        if !shellOnly {
            shellID = UUID().uuidString
        }
        
        guard isReceiptChecked else {
            _ = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true, block: { [weak self] (timer) in
                if isReceiptChecked {
                    self?.runScript(debug: debug, shellOnly: shellOnly)
                    timer.invalidate()
                }
            })
            return
        }
        
        guard isUnlocked else {
            if #available(iOS 13.0, *) {
                (view.window?.windowScene?.delegate as? SceneDelegate)?.showOnboarding()
            }
            return
        }
        
        var task: UIBackgroundTaskIdentifier!
        task = UIApplication.shared.beginBackgroundTask(expirationHandler: {
            UIApplication.shared.endBackgroundTask(task)
        })
        
        // For error handling
        textView.delegate = nil
        textView.delegate = self
        
        guard let path = isScript ? document?.fileURL.path : runFile?.path else {
            return
        }
        
        guard Python.shared.isSetup else {
            _ = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true, block: { [weak self] (timer) in
                if Python.shared.isSetup {
                    self?.runScript(debug: debug, shellOnly: shellOnly)
                    timer.invalidate()
                }
            })
            return
        }
        
        // Shortcuts
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .allDomainsMask)[0]
        if let doc = document?.fileURL,
           (!doc.path.hasPrefix(NSTemporaryDirectory()) && !doc.resolvingSymlinksInPath().path.hasPrefix(NSTemporaryDirectory())),
           (!doc.path.hasPrefix(caches.path) && !doc.resolvingSymlinksInPath().path.hasPrefix(caches.path)), doc.pathExtension.lowercased() == "py" {
            let interaction = INInteraction(intent: runScriptIntent, response: nil)
            interaction.donate { (error) in
                if let error = error {
                    print(error.localizedDescription)
                }
            }
            if let shortcut = INShortcut(intent: runScriptIntent) {
                DispatchQueue.global().async {
                    INVoiceShortcutCenter.shared.setShortcutSuggestions([shortcut])
                }
            }
        }
        
        traceback = nil
        
        save { [weak self] (_) in
            
            guard let self = self else {
                return
            }
            
            if shellOnly {
                (self.parent as? EditorSplitViewController)?.console?.webView.clearInput()
            }
            
            let result = Python.pythonShared?.perform(#selector(PythonRuntime.getString(_:)), with: """
            import shlex
            import base64
            import json
            
            args = base64.b64decode("\(self.args.data(using: .utf8)?.base64EncodedString() ?? "")").decode("utf-8")
            
            s = json.dumps(shlex.split(args))
            """)
            let args = ((try? JSONDecoder().decode([String].self, from: (result?.takeUnretainedValue() as? String)?.data(using: .utf8) ?? Data())) ?? []) as NSArray
            
            guard let console = self.parentPipInstaller?.console ?? (self.parent as? EditorSplitViewController)?.console else {
                return DispatchQueue.main.asyncAfter(deadline: .now()+0.5) {
                    self.runScript(debug: debug)
                }
            }
                        
            (UIApplication.shared.delegate as? AppDelegate)?.addURLToShortcuts(self.document!.fileURL)
            
            #if !Xcode11
            if #available(iOS 14.0, *) {
                PyWidget.widgetCode = self.textView.contentTextView.text
            }
            #endif
            
            DispatchQueue.main.async { [weak self] in
                
                guard let self = self else {
                    return
                }
                
                if let url = isScript ? document?.fileURL : runFile {
                    func run() {
                        if !(self.parent is REPLViewController) && !shellOnly {
                            console.clear()
                        }
                        console.movableTextField?.placeholder = ""
                        if Python.shared.isREPLRunning { // xd
                            if Python.shared.isScriptRunning(path) {
                                return
                            }
                            
                            var breakpoints = [Breakpoint]()
                            for script in BreakpointsStore.shared.breakpoints {
                                breakpoints.append(contentsOf: script.value)
                            }
                            
                            if url.pathExtension.lowercased() == "py" || shellOnly {
                                Python.shared.run(script: Python.Script(path: path, args: args, workingDirectory: directory(for: url).path, debug: debug, runREPL: true, breakpoints: breakpoints, onlyShell: shellOnly, shellID: self.shellID))
                            } else {
                                Python.shared.run(script: Python.PyHTMLPage(path: path, args: args, workingDirectory: directory(for: url).path))
                            }
                        } else {
                            Python.shared.runScriptAt(url)
                        }                        
                    }
                    
                    let editorSplitViewController = console.editorSplitViewController
                    
                    if self.parentPipInstaller == nil {
                        guard console.view.window != nil && editorSplitViewController?.ratio != 1 else {
                            editorSplitViewController?.showConsole {
                                run()
                            }
                            return
                        }
                    } else {
                        editorSplitViewController?.secondChild = console
                    }
                    
                    run()
                }
            }
        }
    }
    
    @objc func saveScript(_ sender: Any) {
        save(completion: { [weak self] _ in
            self?.saveAsIfNeeded()
        })
    }
    
    /// Save the document on a background queue.
    ///
    /// - Parameters:
    ///     - completion: The code executed when the file was saved. A boolean indicated if the file was successfully saved is passed.
    @objc func save(completion: ((Bool) -> Void)? = nil) {
        
        guard document?.fileURL.lastPathComponent.hasSuffix(".repl.py") == false else {
            completion?(true)
            return
        }
        
        guard document != nil else {
            completion?(false)
            return
        }
        
        let text = textView.text
        
        guard document?.text != text else {
            completion?(true)
            return
        }
        
        document?.text = text ?? ""
        document?.updateChangeCount(.done)
        #if MAIN
        setHasUnsavedChanges(isScriptInTemporaryLocation)
        #endif
        
        if document?.documentState != UIDocument.State.editingDisabled {
            
            document?.save(to: document!.fileURL, for: .forOverwriting, completionHandler: completion)
            
            AppDelegate.shared.addURLToShortcuts(document!.fileURL)
        }
    }
    
    /// The View controller is closed and the document is saved.
    @objc func close() {
        
        //stop()
        
        let presenting = presentingViewController
        
        dismiss(animated: true) {
            
            guard !self.isSample else {
                return
            }
            
            self.save(completion: { (_) in
                DispatchQueue.main.async { [weak self] in
                    
                    guard let self = self else {
                        return
                    }
                    
                    self.document?.text = self.textView.text
                    self.document?.close(completionHandler: { (success) in
                        if !success {
                            let alert = UIAlertController(title: NSLocalizedString("errors.errorWrittingToScript", comment: "Title of the alert shown when code cannot be written"), message: nil, preferredStyle: .alert)
                            alert.addAction(UIAlertAction(title: NSLocalizedString("ok", comment: "'Ok' button"), style: .cancel, handler: nil))
                            presenting?.present(alert, animated: true, completion: nil)
                        }
                    })
                }
            })
        }
    }
    
    private func makeDocsIfNeeded() {
        if documentationNavigationController == nil || documentationNavigationController?.viewControllers.count == 0 {
            documentationNavigationController = UINavigationController(rootViewController: DocumentationViewController())
            let docVC = documentationNavigationController?.viewControllers.first as? DocumentationViewController
            docVC?.editor = self
            docVC?.loadViewIfNeeded()
        }
    }
    
    /// Shows documentation
    @objc func showDocs(_ sender: Any) {
        
        guard presentedViewController == nil else {
            return
        }
        
        makeDocsIfNeeded()
        documentationNavigationController?.view.backgroundColor = .systemBackground
        present(documentationNavigationController!, animated: true, completion: nil)
    }
    
    /// Indents current line.
    @objc func insertTab() {
        if let range = textView.contentTextView.selectedTextRange, let selected = textView.contentTextView.text(in: range) {
            
            let nsRange = textView.contentTextView.selectedRange
            
            /*
             location: 3
             length: 37
             
             location: ~40
             length: 0
             
                .
             ->     print("Hello World")
                    print("Foo Bar")| selected
                               - 37
             */
            
            var lines = [String]()
            for line in selected.components(separatedBy: "\n") {
                lines.append(EditorViewController.indentation+line)
            }
            textView.contentTextView.insertText(lines.joined(separator: "\n"))
            
            textView.contentTextView.selectedRange = NSRange(location: nsRange.location, length: textView.contentTextView.selectedRange.location-nsRange.location)
            if selected.components(separatedBy: "\n").count == 1, let range = textView.contentTextView.selectedTextRange {
                textView.contentTextView.selectedTextRange = textView.contentTextView.textRange(from: range.end, to: range.end)
            }
        } else {
            textView.contentTextView.insertText(EditorViewController.indentation)
        }
    }
    
    /// Unindent current line
    @objc func unindent() {
        if let range = textView.contentTextView.selectedTextRange, let selected = textView.contentTextView.text(in: range), selected.components(separatedBy: "\n").count > 1 {
            
            let nsRange = textView.contentTextView.selectedRange
            
            var lines = [String]()
            for line in selected.components(separatedBy: "\n") {
                lines.append(line.replacingFirstOccurrence(of: EditorViewController.indentation, with: ""))
            }
            
            textView.contentTextView.replace(range, withText: lines.joined(separator: "\n"))
            
            textView.contentTextView.selectedRange = NSRange(location: nsRange.location, length: textView.contentTextView.selectedRange.location-nsRange.location)
        } else if let range = textView.contentTextView.currentLineRange, let text = textView.contentTextView.text(in: range) {
            let newRange = textView.contentTextView.textRange(from: range.start, to: range.start)
            textView.contentTextView.replace(range, withText: text.replacingFirstOccurrence(of: EditorViewController.indentation, with: ""))
            textView.contentTextView.selectedTextRange = newRange
        }
    }
    
    /// Comments / Uncomments line.
    @objc func toggleComment() {
        
        guard let selected = textView.contentTextView.selectedTextRange else {
            return
        }
        
        if (textView.contentTextView.text(in: selected)?.components(separatedBy: "\n").count ?? 0) > 1 { // Multiple lines
            guard let line = textView.contentTextView.selectedTextRange else {
                return
            }
            
            guard let text = textView.contentTextView.text(in: line) else {
                return
            }
            
            var newText = [String]()
            
            for line in text.components(separatedBy: "\n") {
                let _line = line.replacingOccurrences(of: " ", with: "").replacingOccurrences(of: "\t", with: "")
                if _line == "" {
                    newText.append(line)
                } else if _line.hasPrefix("#") {
                    newText.append(line.replacingFirstOccurrence(of: "#", with: ""))
                } else {
                    newText.append("#"+line)
                }
            }
            
            textView.contentTextView.replace(line, withText: newText.joined(separator: "\n"))
        } else { // Current line
            guard var line = textView.contentTextView.currentLine else {
                return
            }
            
            let currentLine = line
            
            line = line.replacingOccurrences(of: " ", with: "").replacingOccurrences(of: "\t", with: "")
            
            if line.hasPrefix("#") {
                line = currentLine.replacingFirstOccurrence(of: "#", with: "")
            } else {
                line = "#"+currentLine
            }
            if let lineRange = textView.contentTextView.currentLineRange {
                let location = textView.offset(from: textView.beginningOfDocument, to: lineRange.start)
                let length = textView.offset(from: lineRange.start, to: lineRange.end)
                
                textView.text = (textView.text as NSString).replacingCharacters(in: NSRange(location: location, length: length), with: line)
            }
        }
    }
    
    /// Undo.
    @objc func undo() {
        (textView as? EditorTextView)?.undo()
    }
    
    /// Redo.
    @objc func redo() {
        (textView as? EditorTextView)?.redo()
    }
    
    /// Shows runtime settings.
    @objc func showRuntimeSettings(_ sender: Any) {
        
        guard let navVC = UIStoryboard(name: "ScriptSettingsViewController", bundle: Bundle.main).instantiateInitialViewController() as? UINavigationController else {
            return
        }
        
        guard let vc = navVC.viewControllers.first as? ScriptSettingsViewController else {
            return
        }
        
        vc.editor = self
        
        navVC.modalPresentationStyle = .formSheet
        navVC.preferredContentSize = CGSize(width: 480, height: 640)
        
        present(navVC, animated: true, completion: nil)
    }
    
    // MARK: - Debugger
    
    var replID: String?
    
    struct REPLInspector: SwiftUI.View {
        
        var id: String
        
        var editor: EditorViewController
                
        var body: some SwiftUI.View {
            NavigationView {
                List {
                    ObjectView(object: .namespace(id ?? "", .globals))
                }
                    .toolbar {
                        ToolbarItemGroup(placement: .navigationBarTrailing) {
                            SwiftUI.Button {
                                editor.dismiss(animated: true)
                            } label: {
                                Text("done")
                            }
                        }
                    }
                    .navigationTitle(Text("Globals"))
            }.navigationViewStyle(.stack)
        }
    }
    
    /// The current breakpoint. An array containing the file path and the line number
    @objc static func setCurrentBreakpoint(_ currentBreakpoint: NSArray?, tracebackJSON: String?, id: String, scriptPath: String?) {
        DispatchQueue.main.async {
            for console in ConsoleViewController.visibles {
                guard let editor = console.editorSplitViewController?.editor else {
                    continue
                }
                
                guard editor.document?.fileURL.path == scriptPath || scriptPath == nil else {
                    continue
                }
                
                guard currentBreakpoint != nil else {
                    editor.lastBreakpointFilePath = nil
                    editor.lastBreakpointLineno = nil
                    editor.lastBreakpointID = nil
                    editor.lastTracebackJSON = nil
                    return NotificationCenter.default.post(name: Self.didTriggerBreakpointNotificationName, object: nil, userInfo: [:])
                }
                
                guard currentBreakpoint!.count == 2 else {
                    continue
                }
                
                guard let filePath = currentBreakpoint![0] as? String, let lineno = currentBreakpoint![1] as? Int else {
                    continue
                }
                
                guard FileManager.default.fileExists(atPath: filePath) else {
                    continue
                }
                
                if lineno == -1 { // Not a breakpoint, just inspecting the REPL
                    editor.replID = id
                } else {
                    editor.lastBreakpointFilePath = filePath
                    editor.lastBreakpointLineno = lineno
                    editor.lastBreakpointID = id
                    editor.lastTracebackJSON = tracebackJSON
                    editor.showDebugger(filePath: filePath, lineno: lineno, tracebackJSON: tracebackJSON, id: id, replID: nil)
                }
                
                break
            }
        }
    }
    
    // MARK: - Keyboard
    
    private var previousConstraintValue: CGFloat?
    
    @objc func keyboardDidShow(_ notification:Notification) {
    }
    
    @objc func keyboardWillHide(_ notification:Notification) {
        
        if view.window?.frame.size != view.window?.screen.bounds.size && GCKeyboard.coalesced != nil {
            return
        }
        
        guard let height = (notification.userInfo?["UIKeyboardBoundsUserInfoKey"] as? CGRect)?.height, height > 200 else { // Only software keyboard
            return
        }
        
        if EditorSplitViewController.shouldShowConsoleAtBottom, var previousConstraintValue = previousConstraintValue {
            
            if previousConstraintValue == view.window?.frame.height {
                previousConstraintValue = previousConstraintValue/2
            }
            
            let splitVC = parent as? EditorSplitViewController
            let constraint = (splitVC?.firstViewHeightRatioConstraint?.isActive == true) ? splitVC?.firstViewHeightRatioConstraint : splitVC?.firstViewHeightConstraint
            
            constraint?.constant = previousConstraintValue
            self.previousConstraintValue = nil
        }
    }
    
    @objc func keyboardWillShow(_ notification:Notification) {
        
        if view.window?.frame.size != view.window?.screen.bounds.size && GCKeyboard.coalesced != nil {
            return
        }
        
        guard let height = (notification.userInfo?["UIKeyboardBoundsUserInfoKey"] as? CGRect)?.height, height > 200 else { // Only software keyboard
            return
        }
        
        let splitVC = parent as? EditorSplitViewController
        
        if EditorSplitViewController.shouldShowConsoleAtBottom && textView.isFirstResponder {
            
            splitVC?.firstViewHeightRatioConstraint?.isActive = false
            let constraint = (splitVC?.firstViewHeightRatioConstraint?.isActive == true) ? splitVC?.firstViewHeightRatioConstraint : splitVC?.firstViewHeightConstraint
            
            guard constraint?.constant != 0 else {
                return
            }
            
            previousConstraintValue = constraint?.constant
            constraint?.constant = parent?.view?.frame.height ?? 0
        }
    }
    
    override func pressesBegan(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        guard !completionsHostingController.view.isHidden, completions != [""], !codeCompletionManager.isDocStringExpanded else {
            return super.pressesBegan(presses, with: event)
        }
        
        switch presses.first?.key?.keyCode {
        case .keyboardUpArrow:
            codeCompletionManager.selectedIndex -= 1
        case .keyboardDownArrow:
            codeCompletionManager.selectedIndex += 1
        default:
            super.pressesBegan(presses, with: event)
        }
    }
    
    // MARK: - Text view delegate
    
    /// Taken from https://stackoverflow.com/a/52515645/7515957.
    private func characterBeforeCursor() -> String? {
        // get the cursor position
        if let cursorRange = textView.contentTextView.selectedTextRange {
            // get the position one character before the cursor start position
            if let newPosition = textView.contentTextView.position(from: cursorRange.start, offset: -1) {
                let range = textView.contentTextView.textRange(from: newPosition, to: cursorRange.start)
                return textView.contentTextView.text(in: range!)
            }
        }
        return nil
    }
    
    /// Taken from https://stackoverflow.com/a/52515645/7515957.
    private func characterAfterCursor() -> String? {
        // get the cursor position
        if let cursorRange = textView.contentTextView.selectedTextRange {
            // get the position one character before the cursor start position
            if let newPosition = textView.contentTextView.position(from: cursorRange.start, offset: 1) {
                let range = textView.contentTextView.textRange(from: newPosition, to: cursorRange.start)
                return textView.contentTextView.text(in: range!)
            }
        }
        return nil
    }
    
    func textViewShouldBeginEditing(_ textView: UITextView) -> Bool {
        for console in ConsoleViewController.visibles {
            if console.movableTextField?.textField.isFirstResponder == false {
                continue
            } else {
                console.movableTextField?.textField.resignFirstResponder()
                return false
            }
        }
        return true
    }
    
    fileprivate var lastLineRange: UITextRange?
    
    func textViewDidChangeSelection(_ textView: UITextView) {
        #if !SCREENSHOTS
        
        if textView.isFirstResponder {
            DispatchQueue.main.asyncAfter(deadline: .now()+0.1) {
                self.updateSuggestions()
            }
        }
        #endif
        
        if lastLineRange?.start != textView.currentLineRange?.start, ["c", "cc", "cpp", "cxx", "m", "mm", "h", "hpp"].contains(document?.fileURL.pathExtension.lowercased() ?? "") {
            if #available(iOS 15.0, *) {
                lintCSource(url: document!.fileURL, textView: self.textView) { _ in }
            }
        }
        
        lastLineRange = textView.currentLineRange
    }
    
    @objc static var linterCode: String?
        
    @objc static func setWarnings(_ warnings: String, scriptPath: String) {
        guard #available(iOS 15.0, *) else {
            return
        }
        
        DispatchQueue.main.async {
            for console in ConsoleViewController.visibles {
                guard let editor = console.editorSplitViewController?.editor else {
                    continue
                }
                
                guard editor.document?.fileURL.path == scriptPath else {
                    continue
                }
                
                editor.warnings = Linter.warnings(pylintOutput: warnings)
            }
        }
    }
    
    @objc func lint() {
        guard #available(iOS 15.0, *) else {
            return
        }
        
        self.warnings = [Linter.Warning(type: "linterloading", typeDescription: "", message: "", lineno: 0, url: URL(fileURLWithPath: "/"))]
                
        if document?.fileURL.pathExtension.lowercased() == "py" {
            save { [unowned self] _ in
                Self.linterCode = self.textView.text
                Python.shared.run(code: """
                from pylint import epylint as lint
                from pyto import EditorViewController
                import astroid
                import os.path
                
                def Run(argv = None):
                    from pylint import epylint
                    sys = __import__("sys")
                    argv = argv or sys.argv[1:]
                    sys.exit(epylint.lint(argv[-1], [argv[0]]))
                
                _Run = lint.Run
                lint.Run = Run
                
                script_path = "\(self.document!.fileURL.path.replacingOccurrences(of: "\"", with: "\\\""))"
                threading.current_thread().script_path = "/linter.py"
                
                (pylint_stdout, pylint_stderr) = lint.py_run('--errors-only "'+script_path+'"', return_std=True)
                
                res = pylint_stdout.read()
                EditorViewController.setWarnings(res, scriptPath=script_path)
                
                lint.Run = _Run
                
                astroid.astroid_manager.MANAGER.clear_cache()
                """)
            }
        } else if let url = document?.fileURL, ["c", "cc", "cpp", "cxx", "cc", "h", "hpp", "m", "mm"].contains(url.pathExtension.lowercased()) {
            
            DispatchQueue.global().async {
                lintCSource(url: url, textView: self.textView) { warnings in
                    self.warnings = warnings
                }
            }
        }
    }
    
    func textViewDidChange(_ textView: UITextView) {
        
        #if MAIN
        setHasUnsavedChanges(textView.text != document?.text)
        #endif
        
        let text = textView.text ?? ""
        EditorViewController.isCompleting = true
        DispatchQueue.main.asyncAfter(deadline: .now()+0.5) {
            if textView.text == text {
                EditorViewController.isCompleting = false
            }
        }
        
        if #available(iOS 13.0, *) {
            for scene in UIApplication.shared.connectedScenes {
                
                guard scene != view.window?.windowScene else {
                    continue
                }
                
                let editor = ((scene.delegate as? SceneDelegate)?.sidebarSplitViewController?.sidebar?.editor?.vc as? EditorSplitViewController)?.editor
                
                guard editor?.textView.text != textView.text, editor?.document?.fileURL.path == document?.fileURL.path else {
                    continue
                }
                
                editor?.textView.text = textView.text
            }
        }
        
        if document?.fileURL.pathExtension == "pytoui" {
            for child in (parent as? EditorSplitViewController)?.console?.children ?? [] {
                (child as? PytoUIPreviewViewController)?.preview(self)
            }
        }
    }
    
    
    func textView(_ textView: UITextView, shouldChangeTextIn range: NSRange, replacementText text: String) -> Bool {
        
        docString = nil
        
        if text == "\n", currentSuggestionIndex != -1, completionsHostingController.view.isHidden {
            inputAssistantView(inputAssistant, didSelectSuggestionAtIndex: 0)
            return false
        }
        
        if text == "\n", !completionsHostingController.view.isHidden, codeCompletionManager.completions.indices.contains(codeCompletionManager.selectedIndex) {
            if codeCompletionManager.completions[codeCompletionManager.selectedIndex].isEmpty || codeCompletionManager.isDocStringExpanded {
                completionsHostingController.view.isHidden = true
            } else {
                inputAssistantView(inputAssistant, didSelectSuggestionAtIndex: codeCompletionManager.selectedIndex)
                return false
            }
        }
        
        // Delete new line
        if (textView.text as NSString).substring(with: range) == "\n" {
            let regex = try! NSRegularExpression(pattern: "\n", options: [])
            let lineNumber = regex.numberOfMatches(in: textView.text, options: [], range: NSMakeRange(0, textView.selectedRange.location)) + 1
            
            // Move breakpoints
            var breakpoints = [Breakpoint]()
            for breakpoint in BreakpointsStore.breakpoints(for: document!.fileURL) {
                if breakpoint.url == document?.fileURL && breakpoint.lineno > lineNumber {
                    
                    do {
                        breakpoints.append(try Breakpoint(url: breakpoint.url!, lineno: breakpoint.lineno-1, isEnabled: breakpoint.isEnabled))
                    } catch {
                        breakpoints.append(breakpoint)
                    }
                } else {
                    breakpoints.append(breakpoint)
                }
            }
            
            BreakpointsStore.set(breakpoints: breakpoints, for: document!.fileURL)
        }
        
        if text == "" && range.length == 1, EditorViewController.indentation != "\t" { // Un-indent
            var _range = range
            var rangeToDelete = range
            
            var i = 0
            while true {
                if (_range.location+_range.length <= (textView.text as NSString).length) && _range.location >= 1 && (textView.text as NSString).substring(with: _range) == " " {
                    rangeToDelete = NSRange(location: _range.location, length: i)
                    _range = NSRange(location: _range.location-1, length: _range.length)
                    i += 1
                    
                    if i > EditorViewController.indentation.count {
                        break
                    }
                } else {
                    let oneMoreSpace = NSRange(location: rangeToDelete.location, length: rangeToDelete.length+1)
                    if NSMaxRange(oneMoreSpace) <= (textView.text as NSString).length, (textView.text as NSString).substring(with: oneMoreSpace) == EditorViewController.indentation {
                        rangeToDelete = oneMoreSpace
                    }
                    break
                }
            }
            
            if i < EditorViewController.indentation.count {
                return true
            }
            
            var indentation = ""
            var line = textView.currentLine ?? ""
            while line.hasPrefix(" ") {
                indentation += " "
                line.removeFirst()
            }
            if (indentation.count % EditorViewController.indentation.count) != 0 {
                return true // Not correctly indented, just remove the space
            }
            
            let nextChar = (textView.text as NSString).substring(with: _range)
            if nextChar != "\n" && nextChar != " " {
                return true
            }
            
            if let nsRange = rangeToDelete.toTextRange(textInput: textView) {
                textView.replace(nsRange, withText: "")
                
                let nextChar = NSRange(location: textView.selectedRange.location, length: 1)
                if NSMaxRange(nextChar) <= (textView.text as NSString).length, (textView.text as NSString).substring(with: nextChar) == " " {
                    textView.selectedTextRange = NSRange(location: nextChar.location+1, length: 0).toTextRange(textInput: textView)
                }
                
                return false
            }
        }
        
        if text == "\t" {
            if let textRange = range.toTextRange(textInput: textView) {
                if let selected = textView.text(in: textRange) {
                    
                    let nsRange = textView.selectedRange
                    
                    var lines = [String]()
                    for line in selected.components(separatedBy: "\n") {
                        lines.append(EditorViewController.indentation+line)
                    }
                    textView.replace(textRange, withText: lines.joined(separator: "\n"))
                    
                    textView.selectedRange = NSRange(location: nsRange.location, length: textView.selectedRange.location-nsRange.location)
                    if selected.components(separatedBy: "\n").count == 1, let range = textView.selectedTextRange {
                        textView.selectedTextRange = textView.textRange(from: range.end, to: range.end)
                    }
                }
                return false
            }
        }
        
        // Close parentheses and brackets.
        let completable: [(String, String)] = [
            ("(", ")"),
            ("[", "]"),
            ("{", "}"),
            ("\"", "\""),
            ("'", "'")
        ]
        
        for chars in completable {
            if text == chars.1 {
                let range = textView.selectedRange
                let nextCharRange = NSRange(location: range.location, length: 1)
                let nsText = NSString(string: textView.text)
                
                if nsText.length > nextCharRange.location, nsText.substring(with: nextCharRange) == chars.1 {
                    textView.selectedTextRange = NSRange(location: range.location+1, length: 0).toTextRange(textInput: textView)
                    return false
                }
            }
            
            if (chars == ("\"", "\"") && text == "\"") || (chars == ("'", "'") && text == "'") {
                let range = textView.selectedRange
                let previousCharRange = NSRange(location: range.location-1, length: 1)
                let nsText = NSString(string: textView.text)
                if nsText.length > previousCharRange.location, nsText.substring(with: previousCharRange) == chars.1 {
                    return true
                }
            }
            
            if text == chars.0 {
                
                let range = textView.selectedRange
                let nextCharRange = NSRange(location: range.location, length: 1)
                let nsText = NSString(string: textView.text)
                if nsText.length > nextCharRange.location, !((completable+[(" ", " "), ("\t", "\t"), ("\n", "\n")]).contains(where: { (chars) -> Bool in
                    return nsText.substring(with: nextCharRange) == chars.1
                })) {
                    return true
                } else {
                    textView.insertText(chars.0)
                    let range = textView.selectedTextRange
                    textView.insertText(chars.1)
                    textView.selectedTextRange = range
                    
                    return false
                }
            }
        }
        
        if text == "\n", var currentLine = textView.currentLine, let currentLineRange = textView.currentLineRange, let selectedRange = textView.selectedTextRange {
            
            let regex = try! NSRegularExpression(pattern: "\n", options: [])
            let lineNumber = regex.numberOfMatches(in: textView.text, options: [], range: NSMakeRange(0, textView.selectedRange.location)) + 1
            
            // Move breakpoints
            var breakpoints = [Breakpoint]()
            for breakpoint in BreakpointsStore.breakpoints(for: document!.fileURL) {
                if breakpoint.url == document?.fileURL && breakpoint.lineno > lineNumber {
                    
                    do {
                        breakpoints.append(try Breakpoint(url: breakpoint.url!, lineno: breakpoint.lineno+1, isEnabled: breakpoint.isEnabled))
                    } catch {
                        breakpoints.append(breakpoint)
                    }
                } else {
                    breakpoints.append(breakpoint)
                }
            }
            
            BreakpointsStore.set(breakpoints: breakpoints, for: document!.fileURL)
            
            if selectedRange.start == currentLineRange.start {
                return true
            }
            
            var spaces = ""
            while currentLine.hasPrefix(" ") {
                currentLine.removeFirst()
                spaces += " "
            }
            
            if currentLine.replacingOccurrences(of: " ", with: "").hasSuffix(":") {
                spaces += EditorViewController.indentation
            }
            
            textView.insertText("\n"+spaces)
            
            return false
        }
        
        if text == "" && range.length > 1 {
            // That fixes a very strange bug causing the deletion of an extra space when removing an indented line
            textView.replace(range.toTextRange(textInput: textView) ?? UITextRange(), withText: text)
            return false
        }
        
        return true
    }
    
    func textViewDidEndEditing(_ textView: UITextView) {
        save(completion: nil)
        
        completionsHostingController.view.isHidden = true
        
        parent?.setNeedsUpdateOfHomeIndicatorAutoHidden()
    }
    
    func textViewDidBeginEditing(_ textView: UITextView) {
        
        if let console = (parent as? EditorSplitViewController)?.console, !ConsoleViewController.visibles.contains(console) {
            ConsoleViewController.visibles.append(console)
        }
        
        parent?.setNeedsUpdateOfHomeIndicatorAutoHidden()        
    }
    
    func scrollViewDidScroll(_ scrollView: UIScrollView) {
        if !completionsHostingController.view.isHidden {
            placeCompletionsView()
        }
    }

    // MARK: - Suggestions
    
    /// Linter warnings.
    var warnings = [Any]() {
        didSet {
            guard #available(iOS 15.0, *) else {
                return
            }
            
            (warningsHolder as? LinterView.WarningsHolder)?.warnings = (warnings as? [Linter.Warning]) ?? []
            
            guard let linter = linterVC else {
                return
            }
            
            linter.preferredContentSize = CGSize(width: 500, height: (120*warnings.count)+100)
            linter.modalPresentationStyle = .popover
            linter.popoverPresentationController?.barButtonItem = linterItem
            if #available(iOS 16.0, *) {
                linter.popoverPresentationController?.sourceItem = parentNavigationItem?.overflowPresentationSource
            }
            present(linter, animated: false)
        }
    }
    
    /// Sets the position of the completions view.
    func placeCompletionsView() {
        
        guard textView.isFirstResponder else {
            return
        }
        
        guard let selection = textView.selectedTextRange?.start else {
            return
        }
        
        guard let parent = parent else {
            return
        }
        
        codeCompletionManager.currentWord = textView.text(in: textView.currentWordWithUnderscoreRange ?? UITextRange())
        
        let cursorPosition = parent.view.convert(textView.caretRect(for: selection).origin, from: textView)
        
        completionsHostingController.view.sizeToFit()
        
        completionsHostingController.view.frame.origin = CGPoint(x: cursorPosition.x, y: cursorPosition.y+(textView.font?.pointSize ?? 17)+5)
        
        while completionsHostingController.view.frame.maxX >= parent.view.frame.maxX {
            completionsHostingController.view.frame.origin.x -= 1
        }
        
        let oldY = completionsHostingController.view.frame.origin.y
        if completionsHostingController.view.frame.maxY >= parent.view.frame.maxY {
            completionsHostingController.view.frame.origin.y = cursorPosition.y-completionsHostingController.view.frame.height-(textView.font?.pointSize ?? 17)-5
        }
        
        if completionsHostingController.view.frame.minY <= parent.view.frame.minY {
            completionsHostingController.view.frame.origin.y = oldY
        }
    }
    
    /// The view for code completion on an horizontal size class.
    var completionsHostingController: UIHostingController<CompletionsView>!
    
    /// The definitions of the scripts. Array of arrays: [["content", lineNumber]]
    @objc var definitions = NSMutableArray() {
        didSet {
            DispatchQueue.main.async { [weak self] in
                
                guard let self = self else {
                    return
                }
                
                if let hostC = (self.presentedViewController as? UINavigationController)?.viewControllers.first as? UIHostingController<DefinitionsView> {
                    hostC.rootView.dataSource.definitions = self.definitionsList
                }
            }
        }
    }
    
    /// Definitions of the scripts.
    var definitionsList: [Definition] {
        var definitions = [Definition]()
        for def in self.definitions {
            if let content = def as? [Any], content.count == 8 {
                guard let description = content[0] as? String else {
                    continue
                }
                
                guard let line = content[1] as? Int else {
                    continue
                }
                
                guard let docString = content[2] as? String else {
                    continue
                }
                
                guard let name = content[3] as? String else {
                    continue
                }
                
                guard let signatures = content[4] as? [String] else {
                    continue
                }
                
                guard let _definedNames = content[5] as? [Any] else {
                    continue
                }
                
                guard let moduleName = content[6] as? String else {
                    continue
                }
                
                guard let type = content[7] as? String else {
                    continue
                }
                
                var definedNames = [Definition]()
                
                for _name in _definedNames {
                    
                    guard let name = _name as? [Any] else {
                        continue
                    }
                    
                    guard name.count == 8 else {
                        continue
                    }
                    
                    guard let description = name[0] as? String else {
                        continue
                    }
                    
                    guard let line = name[1] as? Int else {
                        continue
                    }
                    
                    guard let docString = name[2] as? String else {
                        continue
                    }
                    
                    guard let _name = name[3] as? String else {
                        continue
                    }
                    
                    guard let signatures = name[4] as? [String] else {
                        continue
                    }
                    
                    guard let moduleName = name[6] as? String else {
                        continue
                    }
                    
                    guard let type = name[7] as? String else {
                        continue
                    }
                    
                    definedNames.append(Definition(signature: description, line: line, docString: docString, name: _name, signatures: signatures, definedNames: [], moduleName: moduleName, type: type))
                }
                
                definitions.append(Definition(signature: description, line: line, docString: docString, name: name, signatures: signatures, definedNames: definedNames, moduleName: moduleName, type: type))
            }
        
        }
        
        return definitions
    }
    
    private var currentSuggestionIndex = -1 {
        didSet {
            DispatchQueue.main.async { [weak self] in
                self?.inputAssistant.reloadData()
            }
        }
    }
    
    @objc private static var codeToComplete = ""
    
    /// Selects a suggestion from hardware tab key.
    @objc func nextSuggestion() {
        
        guard numberOfSuggestionsInInputAssistantView() != 0 else {
            return
        }
                
        let new = currentSuggestionIndex+1
        
        if suggestions.indices.contains(new) {
            currentSuggestionIndex = new
        } else {
            currentSuggestionIndex = -1
        }
    }
    
    /// Hides suggestion panel.
    @objc func hideSuggestions() {
        completionsHostingController.view.isHidden = true
    }
    
    /// A boolean indicating whether the editor is completing code.
    @objc static var isCompleting = false
    
    let codeCompletionManager = CodeCompletionManager()
    
    /// Returns suggestions for current word.
    @objc var suggestions: [String] {
        
        get {
            
            if _suggestions.indices.contains(currentSuggestionIndex) {
                var completions = _suggestions
                
                let completion = completions[currentSuggestionIndex]
                completions.remove(at: currentSuggestionIndex)
                completions.insert(completion, at: 0)
                return completions
            }
            
            return _suggestions
        }
        
        set {
            
            #if !targetEnvironment(simulator)
            guard document?.fileURL.pathExtension.lowercased() == "html" || lastCodeFromCompletions == text else {
                return
            }
            #endif
            
            guard EditorSplitViewController.shouldShowSuggestions else {
                return
            }
            
            currentSuggestionIndex = -1
            
            _suggestions = newValue
            
            guard !Thread.current.isMainThread else {
                inputAssistant.reloadData()
                codeCompletionManager.isDocStringExpanded = false
                codeCompletionManager.selectedIndex = 0
                completionsHostingController.view.isHidden = ((textView.inputAccessoryView != nil || numberOfSuggestionsInInputAssistantView() == 0) || parent is RunModuleViewController)
                if completionsHostingController.view?.isHidden == false {
                    placeCompletionsView()
                }
                codeCompletionManager.suggestions = newValue
                
                if completions.contains("") && suggestions.count > 0 {
                    codeCompletionManager.isDocStringExpanded = true
                    if textView.inputAccessoryView == nil && completions != suggestions && completions.first != "" && textView.isFirstResponder {
                        completionsHostingController.view.isHidden = false
                    }
                } else if completions != suggestions {
                    codeCompletionManager.isDocStringExpanded = false
                }
                
                return
            }
            
            DispatchQueue.main.async { [weak self] in
                self?.inputAssistant.reloadData()
                self?.codeCompletionManager.selectedIndex = 0
                self?.completionsHostingController.view.isHidden = ((self?.textView.inputAccessoryView != nil || self?.numberOfSuggestionsInInputAssistantView() == 0) || self?.parent is RunModuleViewController)
                self?.codeCompletionManager.suggestions = newValue
                
                if self?.completions.contains("") == true && self?.suggestions.count != 0 {
                    self?.codeCompletionManager.isDocStringExpanded = true
                    if self?.textView.inputAccessoryView == nil && self?.completions != self?.suggestions && self?.completions.first != "" && self?.textView.isFirstResponder == true {
                        self?.completionsHostingController.view.isHidden = false
                    }
                } else if self?.suggestions != self?.completions {
                    self?.codeCompletionManager.isDocStringExpanded = false
                }
                
                if self?.completionsHostingController.view?.isHidden == false {
                    self?.placeCompletionsView()
                }
            }
        }
    }
    
    private var _completions = [String]()
    
    private var _suggestions = [String]()
    
    /// Completions corresponding to `suggestions`.
    @objc var completions: [String] {
        get {
            if _completions.indices.contains(currentSuggestionIndex) {
                var completions = _completions
                
                let completion = completions[currentSuggestionIndex]
                completions.remove(at: currentSuggestionIndex)
                completions.insert(completion, at: 0)
                return completions
            }
            
            return _completions
        }
        
        set {
            
            guard document?.fileURL.pathExtension.lowercased() == "html" || lastCodeFromCompletions == text else {
                return
            }
            
            DispatchQueue.main.async { [weak self] in
                self?.codeCompletionManager.completions = newValue
            }
            _completions = newValue
        }
    }
    
    private var _signature = ""
    
    /// Function or class signature displayed in the completion bar.
    @objc var signature: String {
        get {
            var comps = [String]() // Remove annotations because it's too long
            
            let sig = _signature.components(separatedBy: " ->").first ?? _signature
            
            for component in sig.components(separatedBy: ",") {
                if let name = component.components(separatedBy: ":").first {
                    comps.append(name)
                }
            }
            
            var str = comps.joined(separator: ",")
            if !str.hasSuffix(")") && sig.hasSuffix(")") {
                str.append(")")
            }
            return str
        }
        
        set {
            if newValue != "NoneType()" {
                _signature = newValue
            }
        }
    }
    
    /// Type of each suggestion.
    @objc var suggestionsType = [String:String]() {
        didSet {
            DispatchQueue.main.async {
                self.codeCompletionManager.types = self.suggestionsType
            }
        }
    }
    
    /// Signature of each suggestion.
    @objc var signatures = [String:String]() {
        didSet {
            DispatchQueue.main.async {
                self.codeCompletionManager.signatures = self.signatures
            }
        }
    }
    
    /// Returns doc strings per suggestions.
    @objc var docStrings = [String:String]() {
        didSet {
            DispatchQueue.main.async {
                self.codeCompletionManager.docStrings = self.docStrings
            }
        }
    }
    
    /// The doc string to display.
    @objc var docString: String? {
        didSet {
            
            class DocViewController: UIViewController, UIAdaptivePresentationControllerDelegate {
                
                override func viewLayoutMarginsDidChange() {
                    super.viewLayoutMarginsDidChange()
                    
                    view.subviews.first?.frame = view.safeAreaLayoutGuide.layoutFrame
                }
                
                override func viewWillAppear(_ animated: Bool) {
                    super.viewWillAppear(animated)
                    
                    view.subviews.first?.isHidden = true
                }
                
                override func viewDidAppear(_ animated: Bool) {
                    super.viewDidAppear(animated)
                    
                    view.subviews.first?.frame = view.safeAreaLayoutGuide.layoutFrame
                    view.subviews.first?.isHidden = false
                }
                
                func adaptivePresentationStyle(for controller: UIPresentationController) -> UIModalPresentationStyle {
                    return .none
                }
            }
            
            if presentedViewController != nil, presentedViewController! is DocViewController {
                presentedViewController?.dismiss(animated: false) {
                    self.docString = self.docString
                }
                return
            }
            
            guard docString != nil else {
                return
            }
            
            DispatchQueue.main.async { [weak self] in
                
                guard let self = self else {
                    return
                }
                
                let docView = UITextView()
                docView.textColor = .white
                docView.font = UIFont(name: "Menlo", size: UIFont.systemFontSize)
                docView.isEditable = false
                docView.text = self.docString
                docView.backgroundColor = .black
                
                let docVC = DocViewController()
                docView.frame = docVC.view.safeAreaLayoutGuide.layoutFrame
                docVC.view.addSubview(docView)
                docVC.view.backgroundColor = .black
                docVC.preferredContentSize = CGSize(width: 300, height: 100)
                docVC.modalPresentationStyle = .popover
                docVC.presentationController?.delegate = docVC
                docVC.popoverPresentationController?.backgroundColor = .black
                docVC.popoverPresentationController?.permittedArrowDirections = [.up, .down]
                
                if let selectedTextRange = self.textView.contentTextView.selectedTextRange {
                    docVC.popoverPresentationController?.sourceView = self.textView.contentTextView
                    docVC.popoverPresentationController?.sourceRect = self.textView.contentTextView.caretRect(for: selectedTextRange.end)
                } else {
                    docVC.popoverPresentationController?.sourceView = self.textView.contentTextView
                    docVC.popoverPresentationController?.sourceRect = self.textView.contentTextView.bounds
                }
                
                self.present(docVC, animated: true, completion: nil)
            }
        }
    }
        
    var isCompleting = false
    
    var codeCompletionTimer: Timer?
    
    let completeQueue = DispatchQueue(label: "code-completion")
    
    /// Returns information about the pyhtml Python script tag the cursor is currently in.
    var currentPythonScriptTag: (codeRange: NSRange, code: String, relativeCodeRange: NSRange)? {
            
        let selectedRange = textView.selectedRange
            
        var openScriptTagRange: NSRange?
        var closeScriptTagRange: NSRange?
            
        (text as NSString).enumerateSubstrings(in: NSRange(location: 0, length: selectedRange.location), options: .byLines) { (line, a, b, continue) in
                
            guard let line = line else {
                return
            }
                
            let withoutSpaces = line.replacingOccurrences(of: " ", with: "").replacingOccurrences(of: "\t", with: "")
                
            if withoutSpaces.hasPrefix("<scripttype=") && withoutSpaces.contains("python") {
                    
                openScriptTagRange = a
                `continue`.pointee = false
            }
        }
            
        (text as NSString).enumerateSubstrings(in: NSRange(location: selectedRange.location, length: (text as NSString).length-selectedRange.location), options: .byLines) { (line, a, b, continue) in
            guard let line = line else {
                return
            }
                
            let withoutSpaces = line.replacingOccurrences(of: " ", with: "").replacingOccurrences(of: "\t", with: "")
                
            if withoutSpaces.hasPrefix("</script>") {
                closeScriptTagRange = a
                `continue`.pointee = false
            }
        }
            
        let isInsidePythonScriptTag = openScriptTagRange != nil && closeScriptTagRange != nil
        
        var code: String!
        
        var codeRange: NSRange!
        
        var relativeCodeRange: NSRange!
        
        if isInsidePythonScriptTag {
            let start = openScriptTagRange!.location+openScriptTagRange!.length
            codeRange = NSRange(location: start, length: closeScriptTagRange!.location-start)
            code = (text as NSString).substring(with: codeRange)
            relativeCodeRange = NSRange(location: selectedRange.location-start+1, length: 0)
        }
            
        if !isInsidePythonScriptTag {
            return nil
        } else {
            return (codeRange: codeRange, code: code, relativeCodeRange: relativeCodeRange)
        }
    }
    
    /// Updates suggestions.
    ///
    /// - Parameters:
    ///     - force: If set to `true`, the Python code will be called without doing any check.
    ///     - getDefinitions: If set to `true` definitons will be retrieved, we don't need to update them every time, just when we open the definitions list.
    func updateSuggestions(force: Bool = false, getDefinitions: Bool = false) {
        
        switch document!.fileURL.pathExtension.lowercased() {
        case "c", "cc", "cpp", "cxx", "m", "mm":
            codeCompletionManager.docStrings = [:]
            codeCompletionManager.signatures = [:]
            suggestionsType = [:]
            completionsHostingController.view.isHidden = true
            codeCompletionManager.selectedIndex = -1
            
            /*
             visibleEditor.lastCodeFromCompletions = code
                         visibleEditor.signature = signature
                         visibleEditor.suggestionsType = types
                         visibleEditor.completions = completions
                         visibleEditor.suggestions = suggestions
                         visibleEditor.docStrings = docs
                         visibleEditor.signatures = signatures
             */
            
            let code = textView.text
            let selectedRange = textView.selectedRange
            DispatchQueue.global().async {
                completeCSource(url: self.document!.fileURL, range: selectedRange, textView: self.textView, completionHandler: { [weak self] completions in
                    self?.lastCodeFromCompletions = code
                    for completion in completions {
                        self?.suggestionsType[completion.name] = ""
                    }
                    self?.completions = completions.map({ _ in return "__is_fuzzy__" })
                    self?.suggestions = completions.map({ $0.name })
                    self?.docStrings = [:]
                    for completion in completions {
                        self?.signatures[completion.name] = completion.signature
                    }
                })
            }
        default:
            break
        }
        
        guard document?.fileURL.pathExtension.lowercased() == "py" || document?.fileURL.pathExtension.lowercased() == "html" else {
            return
        }
                
        let currentPythonScriptTag = self.currentPythonScriptTag
        let text = currentPythonScriptTag?.code ?? self.text
        
        if currentPythonScriptTag == nil && document?.fileURL.pathExtension.lowercased() == "html" {
            return
        }
                
        guard let textRange = textView.selectedTextRange else {
            return
        }
        
        if !force && !getDefinitions {
            guard let line = textView.currentLine, !line.isEmpty else {
                self.suggestions = []
                self.completions = []
                self.signature = ""
                codeCompletionManager.docStrings = [:]
                codeCompletionManager.signatures = [:]
                suggestionsType = [:]
                completionsHostingController.view.isHidden = true
                codeCompletionManager.selectedIndex = -1
                return inputAssistant.reloadData()
            }
        }
                
        var location = 0
        if currentPythonScriptTag == nil {
            guard let range = textView.textRange(from: textView.beginningOfDocument, to: textRange.end) else {
                return
            }
            for _ in textView.text(in: range) ?? "" {
                location += 1
            }
        } else {
            location = currentPythonScriptTag!.relativeCodeRange.location-1
        }
        
        EditorViewController.codeToComplete = text
                
        ConsoleViewController.ignoresInput = true
        
        codeCompletionManager.docStrings = [:]
        codeCompletionManager.signatures = [:]
        
        suggestionsType = [:]
        
        completionsHostingController.view.isHidden = true
        codeCompletionManager.selectedIndex = -1
        
        let code =
        """
        from pyto import Python
        from threading import Thread

        def complete():
            from pyto import EditorViewController
            from _codecompletion import suggestForCode
            import os
        
            #try:
            #    sys.modules["sys"]
            #except KeyError:
            #    sys.modules["sys"] = sys

            Python.shared.handleCrashesForCurrentThread()

            path = '\(self.currentDirectory.path.replacingOccurrences(of: "'", with: "\\'"))'
            
            os.chdir(path)
        
            if not path in sys.path:
                sys.path.append(path)
                
            source = str(EditorViewController.codeToComplete)
            suggestForCode(source, \(location), '\((self.document?.fileURL.path ?? "").replacingOccurrences(of: "'", with: "\\'"))', \(getDefinitions ? "True" : "False"))

        thread = Thread(target=complete)
        thread.script_path = '\((self.document?.fileURL.path ?? "").replacingOccurrences(of: "'", with: "\\'"))'
        thread.start()
        thread.join()
        """
        
        func complete() {
            isCompleting = true
            completeQueue.async { [weak self] in
                Python.pythonShared?.perform(#selector(PythonRuntime.runCode(_:)), with: code)
                self?.isCompleting = false
            }
        }
        
        if isCompleting { // A timer so it doesn't block the main thread
            
            if !(codeCompletionTimer?.isValid == true) {
                codeCompletionTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true, block: { [weak self] (timer) in
                    
                    if self?.isCompleting == false && timer.isValid {
                        complete()
                        timer.invalidate()
                    }
                })
            }
        } else {
            complete()
        }
    }
    
    @objc func toggleCompletionsView(_ sender: Any) {
        placeCompletionsView()
        completionsHostingController.view.isHidden.toggle()
    }
    
    // MARK: - Input assistant view delegate
    
    func inputAssistantView(_ inputAssistantView: InputAssistantView, didSelectSuggestionAtIndex index: Int) {
        
        guard completions.indices.contains(index), suggestions.indices.contains(index) else {
            currentSuggestionIndex = -1
            return
        }
        
        var completion = completions[index]
        var suggestion = suggestions[index]
        
        let isFuzzy: Bool
        if completion == "__is_fuzzy__" {
            completion = suggestion
            isFuzzy = true
        } else {
            isFuzzy = false
        }
        
        var isParam = false
        
        if suggestion.hasSuffix("=") {
            suggestion.removeLast()
            isParam = true
        }
        
        if isFuzzy, let wordRange = textView.currentWordWithUnderscoreRange {
            let location = textView.offset(from: textView.beginningOfDocument, to: wordRange.start)
            let length = textView.offset(from: wordRange.start, to: wordRange.end)
            let nsRange = NSRange(location: location, length: length)
            var text = textView.text as NSString
            text = text.replacingCharacters(in: nsRange, with: "") as NSString
            textView.text = text as String
            
            textView.selectedTextRange = textView.textRange(from: wordRange.start, to: wordRange.start)
        }
        
        let selectedRange = textView.contentTextView.selectedRange
        
        let location = selectedRange.location-(suggestion.count-completion.count)
        let length = suggestion.count-completion.count
        
        /*
         
         hello_w HELLO_WORLD ORLD
         
         */
        
        let iDonTKnowHowToNameThisVariableButItSSomethingWithTheSelectedRangeButFromTheBeginingLikeTheEntireSelectedWordWithUnderscoresIncluded = NSRange(location: location, length: length)
        
        textView.contentTextView.selectedRange = iDonTKnowHowToNameThisVariableButItSSomethingWithTheSelectedRangeButFromTheBeginingLikeTheEntireSelectedWordWithUnderscoresIncluded
        
        DispatchQueue.main.asyncAfter(deadline: .now()+0.1) { [weak self] in
            
            guard let self = self else {
                return
            }
            
            self.textView.contentTextView.insertText(suggestion)
            if suggestion.hasSuffix("(") {
                let range = self.textView.contentTextView.selectedRange
                self.textView.contentTextView.insertText(")")
                self.textView.contentTextView.selectedRange = range
            }
            
            if isParam {
                self.textView.contentTextView.insertText("=")
            }
        }
        
        completionsHostingController.view.isHidden = true
                
        currentSuggestionIndex = -1
    }
    
    // MARK: - Input assistant view data source
    
    func textForEmptySuggestionsInInputAssistantView() -> String? {
        nil
    }
    
    func numberOfSuggestionsInInputAssistantView() -> Int {
        
        #if !targetEnvironment(simulator)
        guard document?.fileURL.pathExtension.lowercased() == "html" || lastCodeFromCompletions == text else {
            return 0
        }
        #endif
        
        guard EditorSplitViewController.shouldShowSuggestions else {
            return 0
        }
        
        #if !SCREENSHOTS
        if let currentTextRange = textView.contentTextView.selectedTextRange {
            
            var range = textView.contentTextView.selectedRange
            
            if range.length > 1 {
                return 0
            }
            
            if textView.contentTextView.text(in: currentTextRange) == "" {
                
                range.length += 1
                
                let word = textView.contentTextView.currentWord?.replacingOccurrences(of: " ", with: "").replacingOccurrences(of: "\t", with: "")
                
                if word == "\"\"\"" || word == "'''" {
                    return 0
                } else if word?.isEmpty != false {
                    
                    range.location -= 1
                                        
                    if let range = range.toTextRange(textInput: textView.contentTextView), [
                        "(",
                        "[",
                        "{"
                    ].contains(textView.text(in: range) ?? "") {
                        return suggestions.count
                    } else if let currentLineStart = textView.currentLineRange?.start, let cursor = textView.selectedTextRange?.start, let range = textView.textRange(from: currentLineStart, to: cursor), let text = textView.text(in: range), text.replacingOccurrences(of: " ", with: "").hasSuffix(","), cursor != textView.currentLineRange?.end {
                        return suggestions.count
                    } else {
                        return 0
                    }
                }
                
                range.location -= 1
                if let textRange = range.toTextRange(textInput: textView.contentTextView), let word = textView.contentTextView.word(in: range), let last = word.last, String(last) != textView.contentTextView.text(in: textRange) || completions.contains("") {
                    return 0
                }
            }
        }
        #endif
        
        return suggestions.count
    }
    
    func inputAssistantView(_ inputAssistantView: InputAssistantView, nameForSuggestionAtIndex index: Int) -> String {
        
        let suffix: String = ((currentSuggestionIndex != -1 && index == 0) ? " ⤶" : "")
        
        guard suggestions.indices.contains(index) else {
            return ""
        }
        
        if suggestions[index].hasSuffix("(") {
            return "()"+suffix
        }
        
        return suggestions[index]+suffix
    }
    
    // MARK: - Document picker delegate
    
    func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
        let success = urls.first?.startAccessingSecurityScopedResource()
        
        let url = urls.first ?? currentDirectory
        
        func doChange() {
            currentDirectory = url
            if !FoldersBrowserViewController.accessibleFolders.contains(currentDirectory.resolvingSymlinksInPath()) {
                FoldersBrowserViewController.accessibleFolders.append(currentDirectory.resolvingSymlinksInPath())
            }
            
            if success == true {
                for item in (parentVC?.toolbarItems ?? []).enumerated() {
                    if item.element.action == #selector(setCwd(_:)) {
                        parentVC?.toolbarItems?.remove(at: item.offset)
                        break
                    }
                }
            }
        }
        
        if let file = document?.fileURL,
            url.appendingPathComponent(file.lastPathComponent).resolvingSymlinksInPath() == file.resolvingSymlinksInPath() {
            
            doChange()
        } else {
            
            let alert = UIAlertController(title: NSLocalizedString("couldNotAccessScriptAlert.title", comment: "Title of the alert shown when setting a current directory not containing the script"), message: NSLocalizedString("couldNotAccessScriptAlert.message", comment: "Message of the alert shown when setting a current directory not containing the script"), preferredStyle: .alert)
            
            alert.addAction(UIAlertAction(title: NSLocalizedString("couldNotAccessScriptAlert.useAnyway", comment: "Use anyway"), style: .destructive, handler: { (_) in
                doChange()
            }))
            
            alert.addAction(UIAlertAction(title: NSLocalizedString("couldNotAccessScriptAlert.selectAnotherLocation", comment: "Select another location"), style: .default, handler: { (_) in
                self.setCwd(alert)
            }))
            
            alert.addAction(UIAlertAction(title: NSLocalizedString("cancel", comment: "'Cancel' button"), style: .cancel, handler: { (_) in
                urls.first?.stopAccessingSecurityScopedResource()
            }))
            
            present(alert, animated: true, completion: nil)
        }
    }
}

@available(iOS 16.0, *)
extension EditorViewController: UINavigationItemRenameDelegate {
    
    func navigationItem(_ navigationItem: UINavigationItem, willBeginRenamingWith suggestedTitle: String, selectedRange: Range<String.Index>) -> (String, Range<String.Index>) {
        
        DispatchQueue.main.asyncAfter(deadline: .now()+0.5) {
            guard let window = self.view.window else {
                return
            }
            
            guard let textField = findFirstResponder(inView: window) as? UITextField else {
                return
            }
                        
            textField.autocorrectionType = .no
            textField.autocapitalizationType = .none
            textField.smartDashesType = .no
            textField.smartQuotesType = .no
            textField.spellCheckingType = .no
        }
        
        return (suggestedTitle, selectedRange)
    }
    
    func navigationItem(_ navigationItem: UINavigationItem, didEndRenamingWith title: String) {
        guard let url = document?.fileURL else {
            return
        }
        
        var newURL = url.deletingLastPathComponent().appendingPathComponent(title)
        if !title.lowercased().hasSuffix(url.pathExtension.lowercased()) {
            newURL.appendPathExtension(url.pathExtension)
        }
        
        guard newURL != url else {
            return
        }
        
        save { _ in
            self.document?.close(completionHandler: { _ in
                do {
                    try FileManager.default.moveItem(at: url, to: newURL)
                    let document = PyDocument(fileURL: newURL)
                    document.open { _ in
                        self.isDocOpened = false
                        self.parent?.title = document.fileURL.lastPathComponent
                        self.document = document
                        self.viewWillAppear(false)
                        self.appKitWindow.representedURL = document.fileURL
                    }
                } catch {
                    DispatchQueue.main.async {
                        let alert = UIAlertController(title: NSLocalizedString("error", comment: "Error"), message: error.localizedDescription, preferredStyle: .alert)
                        alert.addAction(UIAlertAction(title: NSLocalizedString("cancel", comment: "Cancel"), style: .cancel))
                        self.present(alert, animated: true)
                    }
                }
            })
        }
    }
    
    func navigationItemShouldBeginRenaming(_: UINavigationItem) -> Bool {
        document != nil && FileManager.default.isWritableFile(atPath: document!.fileURL.deletingLastPathComponent().path)
    }
}
#endif
