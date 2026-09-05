// A paginated body's size can stay fixed while translations move text within
// its columns. ResizeObserver alone cannot detect that reflow.
export function observeContentLayout(doc, onLayout) {
    const view = doc.defaultView
    let frame = null
    let disposed = false
    const schedule = () => {
        if (disposed || frame !== null) return
        frame = view.requestAnimationFrame(() => {
            frame = null
            if (!disposed) onLayout()
        })
    }
    const observer = new view.MutationObserver(records => {
        if (records.some(record => {
            if (record.type === 'attributes')
                return record.oldValue !== record.target.getAttribute(record.attributeName)
            if (record.type === 'characterData')
                return record.oldValue !== record.target.data
            return record.addedNodes.length > 0 || record.removedNodes.length > 0
        })) schedule()
    })
    observer.observe(doc.body, {
        subtree: true, childList: true, characterData: true,
        characterDataOldValue: true, attributes: true, attributeOldValue: true,
        attributeFilter: ['style', 'class', 'hidden'],
    })
    doc.addEventListener('load', schedule, true)
    doc.fonts?.addEventListener?.('loadingdone', schedule)
    return () => {
        disposed = true
        observer.disconnect()
        if (frame !== null) view.cancelAnimationFrame(frame)
        doc.removeEventListener('load', schedule, true)
        doc.fonts?.removeEventListener?.('loadingdone', schedule)
    }
}
