import UIKit

/// A protocol for implementing a view that is available on the views library. Contains information about the type of view, implements preview and a configuration when the view is placed.
public protocol InterfaceBuilderView {
    
    /// The type of view.
    var type: UIView.Type { get }
    
    /// If a color is returned, a square with that color will be shown as preview on the library.
    var previewColor: UIColor? { get }
    
    /// If `previewColor` is not set, called for configuring `view` for preview.
    ///
    /// - Parameters:
    ///     - view: View shown as preview.
    func preview(view: UIView)
    
    /// Called to configure `view` when it's dropped.
    ///
    /// - Parameters:
    ///     - view: View generated by the library.
    ///     - model: The interface builder.
    func configure(view: UIView, model: inout InterfaceModel)
    
    /// Called to initialize the view. The default implementation calls `init` with no parameters.
    func makeView() -> UIView
    
    /// An image representing the view.
    var image: UIImage? { get }
    
    /// The display name for the library browser.
    var customDisplayName: String? { get }
    
}

extension InterfaceBuilderView {
    
    public func makeView() -> UIView {
        type.init()
    }
    
    public var customDisplayName: String? { nil }
}
