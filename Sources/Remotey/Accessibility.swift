import ApplicationServices

/// Reading what an app reports about its interface. Every call is a round trip to that app.
enum Accessibility {
    /// Nil if the app does not know the attribute, does not answer in time, or Remotey lacks the permission.
    static func attribute(_ element: AXUIElement, _ name: String) -> CFTypeRef? {
        var result: CFTypeRef?
        return AXUIElementCopyAttributeValue(element, name as CFString, &result) == .success ? result : nil
    }

    /// A point, size, rectangle or range out of the box Accessibility hands it over in.
    static func value<T>(_ ref: CFTypeRef?, _ type: AXValueType) -> T? {
        guard let ref, CFGetTypeID(ref) == AXValueGetTypeID() else { return nil }
        let axValue = ref as! AXValue // swiftlint:disable:this force_cast
        guard AXValueGetType(axValue) == type else { return nil }
        let pointer = UnsafeMutablePointer<T>.allocate(capacity: 1)
        defer { pointer.deallocate() }
        return AXValueGetValue(axValue, type, pointer) ? pointer.pointee : nil
    }

    /// Where an element is, in global points with the origin at the top left of the main display.
    static func frame(of element: AXUIElement) -> CGRect? {
        guard let position: CGPoint = value(attribute(element, kAXPositionAttribute), .cgPoint),
              let size: CGSize = value(attribute(element, kAXSizeAttribute), .cgSize) else { return nil }
        return CGRect(origin: position, size: size)
    }
}
