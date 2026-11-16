import AppKit
import ImageconverterCore

/// The window height: worked out from the sidebar's measured parts, then followed frame by frame.
extension WindowSizer {
    /// The sidebar measured its parts (natural heights) with the pipeline collapsed or expanded.
    func sidebarMeasured(_ parts: WindowLayout.SidebarParts, collapsed: Bool) {
        // The first layout after an Output resize: let the pin go, judged with these fresh parts.
        if releasePending, pinnedHeight != nil {
            finishRelease(parts: parts, collapsed: collapsed)
            return
        }
        let toggled = pipelineCollapsed.map { $0 != collapsed } ?? false
        let shownBefore = targetHeight
        self.parts = parts
        pipelineCollapsed = collapsed
        let maxContent = currentMaxContent
        let height: CGFloat
        if collapsed {
            height = WindowLayout.fittingHeight(contentHeight: parts.collapsed, maxContent: maxContent)
            previousExpanded = nil
        } else if let pinned = pinnedHeight {
            // The Output panel is being dragged: the window stays (within what the parts allow); no animation.
            let range = WindowLayout.expandedHeights(parts: parts, maxContent: maxContent)
            height = min(max(pinned, range.lowerBound), range.upperBound)
            previousExpanded = parts.expanded
        } else {
            let result = WindowLayout.expandedHeight(parts: parts, remembered: rememberedHeight,
                                                     previousContent: previousExpanded, maxContent: maxContent)
            height = result.height
            setRemembered(result.remembered)
            previousExpanded = parts.expanded
        }
        if toggled, let from = shownBefore {
            let collapsedHeight = collapsed ? height : from
            let expandedHeight = collapsed ? from : height
            toggleSpan = expandedHeight - collapsedHeight > 0.5 ? (collapsedHeight, expandedHeight) : nil
        }
        guard targetHeight.map({ abs($0 - height) > 0.5 }) ?? true else {
            // Nothing to animate: settle at once (a collapse that changes no height still hides the details).
            if toggled { pipelineReveal = collapsed ? 0 : 1 }
            applyRestLimits()
            return
        }
        targetAnimates = didInitialSize && window != nil && !isLiveResizing && pinnedHeight == nil
            && SidebarMotion.animation != nil
        if targetAnimates, !isAnimating { isAnimating = true }
        targetHeight = height
    }

    /// The window content height the sidebar shows at this frame (animated towards `targetHeight`).
    /// The window is set to it at once, so its edge and the content move together.
    func sidebarShown(_ shown: CGFloat) {
        // Before the first size, or while a preview toggle animates the frame, that path takes the height.
        guard didInitialSize, !isResizing, !isLiveResizing, let window, let current = currentContentSize else {
            if !isLiveResizing { resize(animated: didInitialSize) }
            if !didInitialSize { pipelineReveal = pipelineCollapsed == true ? 0 : 1 }
            return
        }
        generation += 1
        let settled = targetHeight.map { abs(shown - $0) < 0.5 } ?? true
        updateReveal(shown: shown, settled: settled)
        let visible = window.screen?.visibleFrame ?? NSScreen.main?.visibleFrame ?? window.frame
        let chrome = Self.chrome(of: window)
        let maxContent = CGSize(width: visible.width - chrome.width, height: visible.height - chrome.height)
        let size = WindowLayout.targetSize(previewShown: previewShown, current: current, contentHeight: shown,
                                           requestedWidth: nil, maxContent: maxContent)
        let rest = restLimits(height: size.height, maxContent: maxContent)
        let heights = settled ? rest.height : WindowLayout.followingHeights(maxContent: maxContent)
        if widthRange != rest.width { widthRange = rest.width }
        if heightRange != heights { heightRange = heights }
        if isAnimating == settled { isAnimating = !settled }
        let frame = WindowLayout.frame(contentSize: size, chrome: chrome, currentFrame: window.frame, visible: visible)
        if frame != window.frame { window.setFrame(frame, display: true) }
    }

    /// The window's limits at rest for a content height, in the current pipeline state.
    func restLimits(height: CGFloat, maxContent: CGSize) -> WindowLayout.Limits {
        let heights = parts.map {
            WindowLayout.restHeights(collapsed: pipelineCollapsed ?? true, parts: $0, height: height,
                                     maxContent: maxContent)
        } ?? height...height
        return WindowLayout.limits(previewShown: previewShown, heights: heights, maxContent: maxContent)
    }

    #if DEBUG
    /// `-debugWindowHeight <points>`: as if the user had resized the expanded window to that height.
    func debugRemember(height: CGFloat) {
        setRemembered(height)
        if let parts, let collapsed = pipelineCollapsed { sidebarMeasured(parts, collapsed: collapsed) }
    }
    #endif

    /// The Output panel is being resized from its handle (a drag, an arrow key, a VoiceOver adjustment): the window
    /// keeps its current height while the panel grows or shrinks, and the pipeline steps above take up the difference.
    func pinHeight() {
        guard pipelineCollapsed == false else { return }
        if pinnedHeight == nil {
            pinnedHeight = targetHeight ?? currentContentSize?.height
            rememberedBeforePin = rememberedHeight
        }
        releasePending = false
    }

    /// The resize is done (or the drag was cancelled): the pin is let go at the next measured layout, so the
    /// decision sees the panel's new height (`WindowLayout.releasedRememberedHeight`). A change that moves no
    /// measured height lets it go shortly after instead.
    func requestRelease() {
        guard pinnedHeight != nil else { return }
        releasePending = true
        releaseToken += 1
        let token = releaseToken
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
            guard let self, token == releaseToken, releasePending, let parts else { return }
            finishRelease(parts: parts, collapsed: pipelineCollapsed ?? false)
        }
    }

    private func finishRelease(parts: WindowLayout.SidebarParts, collapsed: Bool) {
        guard let pinned = pinnedHeight else { return }
        releasePending = false
        pinnedHeight = nil
        if !collapsed {
            setRemembered(WindowLayout.releasedRememberedHeight(pinned: pinned, parts: parts,
                                                                rememberedBefore: rememberedBeforePin,
                                                                maxContent: currentMaxContent))
        }
        // Now unpinned: the window settles by the usual rules, animated (closing a gap the change left).
        sidebarMeasured(parts, collapsed: collapsed)
    }

    /// The user finished resizing: an expanded window keeps (and remembers) the height they chose.
    func liveResizeEnded() {
        isLiveResizing = false
        guard pipelineCollapsed == false, let parts, let height = currentContentSize?.height,
              let target = targetHeight, abs(height - target) > 0.5 else { return }
        // Back at the content's own height: fit the content again from now on.
        setRemembered(abs(height - parts.expanded) < 1 ? nil : height)
        targetAnimates = false
        targetHeight = height
        applyRestLimits()
    }

    func setRemembered(_ height: CGFloat?) {
        guard height != rememberedHeight else { return }
        rememberedHeight = height
        if let height { defaults.set(Double(height), forKey: Self.rememberedHeightKey) } else {
            defaults.removeObject(forKey: Self.rememberedHeightKey)
        }
    }

    private func updateReveal(shown: CGFloat, settled: Bool) {
        let value: CGFloat
        if let span = toggleSpan, !settled {
            value = min(max((shown - span.collapsed) / (span.expanded - span.collapsed), 0), 1)
        } else {
            value = pipelineCollapsed == true ? 0 : 1
            if settled { toggleSpan = nil }
        }
        if abs(value - pipelineReveal) > 0.0001 { pipelineReveal = value }
    }

    private func applyRestLimits() {
        guard !isResizing, let height = currentContentSize?.height else { return }
        let rest = restLimits(height: height, maxContent: currentMaxContent)
        if widthRange != rest.width { widthRange = rest.width }
        if heightRange != rest.height { heightRange = rest.height }
    }

    /// The largest content size on the window's screen (unbounded before there is a window).
    private var currentMaxContent: CGSize {
        guard let window else { return CGSize(width: CGFloat.infinity, height: CGFloat.infinity) }
        let visible = window.screen?.visibleFrame ?? NSScreen.main?.visibleFrame ?? window.frame
        let chrome = Self.chrome(of: window)
        return CGSize(width: visible.width - chrome.width, height: visible.height - chrome.height)
    }
}
