import ImageconverterCore

/// The preview's alt text for one render: generating, or what the model gave.
struct PreviewAltText: Equatable {
    enum State: Equatable {
        case generating
        case done(AltTextOutcome)
    }

    let key: String
    let state: State
}

extension AppModel {
    /// What the shown preview asks the model (nil: no alt text asked for, or the render failed).
    var altTextRequest: AltTextRequest? {
        previewFailure == nil ? previewResult?.altTextRequest : nil
    }

    /// Generates (or takes from the renderer's cache) the alt text the batch would write for the shown preview.
    /// Runs from the preview pane's `task(id: altTextRequest)`, so a new render with other pixels cancels it.
    func generatePreviewAltText(for request: AltTextRequest?) async {
        guard let request else {
            previewAltText = nil
            return
        }
        if let shown = previewAltText, shown.key == request.key, case .done = shown.state { return }
        previewAltText = PreviewAltText(key: request.key, state: .generating)
        let outcome = await previewRenderer.altText(for: request)
        guard !Task.isCancelled, altTextRequest?.key == request.key else { return }
        previewAltText = PreviewAltText(key: request.key, state: .done(outcome))
    }
}
