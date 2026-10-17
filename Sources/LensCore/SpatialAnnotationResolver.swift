import Foundation

public enum SpatialAnnotationResolver {
    public static func references(annotations: [Annotation], capture: CaptureRecord) -> [String] {
        bindings(annotations: annotations, capture: capture).compactMap { $0["sourceRef"]?.stringValue }.reduce(into: []) { result, value in if !result.contains(value) { result.append(value) } }
    }
    public static func bindings(annotations: [Annotation], capture: CaptureRecord) -> [JSONValue] {
        annotations.filter { $0.kind != "mask" }.map { annotation in
            let miss: JSONValue = .object(["annotationId": .string(annotation.id), "omission": .string("No stable source element could be associated with this annotation.")])
            guard capture.context["coordinateSpace"]?.stringValue == "browser-viewport",
                  capture.context["captureId"]?.stringValue == capture.id,
                  capture.context["documentId"]?.stringValue == capture.identity.documentId,
                  let viewport = capture.context["viewport"], let width = viewport["width"]?.doubleValue, let height = viewport["height"]?.doubleValue,
                  width.isFinite, height.isFinite, width > 0, height > 0, !annotation.points.isEmpty else { return miss }
            let target: NormalizedPoint
            if annotation.kind == "arrow", let last = annotation.points.last { target = last }
            else {
                let xs = annotation.points.map(\.x), ys = annotation.points.map(\.y)
                target = NormalizedPoint(x: ((xs.min() ?? 0) + (xs.max() ?? 0)) / 2, y: ((ys.min() ?? 0) + (ys.max() ?? 0)) / 2)
            }
            let point = CGPoint(x: target.x * width, y: target.y * height)
            let candidates = (capture.context["elements"]?.arrayValue ?? []).compactMap { element -> (JSONValue, Double)? in
                guard element["captureId"]?.stringValue == capture.id,
                      element["documentId"]?.stringValue == capture.identity.documentId,
                      element["tabId"]?.intValue == capture.identity.tabId,
                      element["binding"]?.stringValue == "stable-across-capture",
                      let source = element["source"]?.stringValue, !source.isEmpty,
                      let bounds = element["bounds"], let x = bounds["x"]?.doubleValue, let y = bounds["y"]?.doubleValue,
                      let w = bounds["width"]?.doubleValue, let h = bounds["height"]?.doubleValue,
                      [x, y, w, h].allSatisfy(\.isFinite), w > 0, h > 0,
                      CGRect(x: x, y: y, width: w, height: h).contains(point) else { return nil }
                return (element, w * h)
            }
            guard let element = candidates.min(by: { $0.1 < $1.1 })?.0, let source = element["source"] else { return miss }
            return .object(["annotationId": .string(annotation.id), "sourceRef": source, "elementAnchorId": element["anchorId"] ?? .null,
                "captureId": .string(capture.id), "documentId": .string(capture.identity.documentId), "tabId": .number(Double(capture.identity.tabId)),
                "point": .object(["x": .number(target.x), "y": .number(target.y)])])
        }
    }
}
