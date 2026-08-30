export const TranslationMode = {
  OFF: 'off',
  TRANSLATION_ONLY: 'translation-only',
  ORIGINAL_ONLY: 'original-only',
  BILINGUAL: 'bilingual'
}

if (typeof window !== 'undefined') window.TranslationMode = TranslationMode

const PERMANENT_TRANSLATION_ERROR =
  /authentication failed|invalid api key|api key in settings|service not configured/i
const TRANSLATION_ERROR =
  /^(?:error:|translation error:|translate error:|translation failed:)|translation failed after/i

class TranslationRequestError extends Error {
  constructor(message, { retryable = true } = {}) {
    super(message)
    this.name = 'TranslationRequestError'
    this.retryable = retryable
  }
}

// Keep bridge failures out of successful element state. A later lifecycle
// reconciliation may retry transient failures; permanent configuration and
// authentication failures remain quiescent for the document.
const translate = async (text, contextText) => {
  const result = await window.flutter_inappwebview.callHandler(
    'translateText', text, contextText)
  const translatedText = typeof result === 'string' ? result.trim() : ''
  if (!translatedText || TRANSLATION_ERROR.test(translatedText) ||
      PERMANENT_TRANSLATION_ERROR.test(translatedText)) {
    throw new TranslationRequestError(
      translatedText || 'Translation returned an empty result',
      { retryable: !PERMANENT_TRANSLATION_ERROR.test(translatedText) },
    )
  }
  return result
}

export class Translator {
  #translationMode = TranslationMode.OFF
  #documents = new Map()
  #elementOwners = new WeakMap()
  #translatedElements = new WeakMap()
  #translationInputs = new WeakMap()
  #inFlightElements = new WeakMap()
  #failedElements = new WeakMap()
  #observer = null

  constructor() {
    this.#initializeObserver()
  }

  #initializeObserver() {
    this.#observer = new IntersectionObserver(
      entries => {
        entries.forEach(entry => {
          if (entry.isIntersecting) {
            this.#reconcileElement(entry.target).catch(error =>
              console.warn('Translation failed in observer:', error)
            )
          }
        })
      },
      { rootMargin: '1280px', threshold: 0 },
    )
  }

  async setTranslationMode(mode) {
    if (!Object.values(TranslationMode).includes(mode)) {
      console.warn(`Invalid translation mode: ${mode}`)
      return
    }

    const oldMode = this.#translationMode
    this.#translationMode = mode

    if (oldMode !== mode) {
      if (mode === TranslationMode.OFF) {
        this.#updateTranslationDisplay()
      } else if (oldMode === TranslationMode.OFF) {
        // Joining element-scoped operations makes this safe when an observer
        // callback is already translating the same element. Explicitly
        // re-enabling translation also permits a retry after settings change.
        this.#failedElements = new WeakMap()
        await this.reconcileDocuments()
      } else {
        this.#updateTranslationDisplay()
      }
    }

    if (window.reader && window.reader.annotationsById) {
      const existingAnnotations = Array.from(window.reader.annotationsById.values())
      if (existingAnnotations.length > 0) {
        window.renderAnnotations(existingAnnotations)
      }
    }
  }

  getTranslationMode() {
    return this.#translationMode
  }

  observeDocument(doc) {
    if (!doc) {
      console.warn('No document provided to observeDocument')
      return
    }

    let documentState = this.#documents.get(doc)
    if (!documentState) {
      documentState = {
        doc,
        elements: new Set(),
        active: true,
        reconciliationScheduled: false,
        visibleRange: undefined,
      }
      this.#documents.set(doc, documentState)
    }

    const textElements = this.#walkTextNodes(doc.body || doc.documentElement)
    let previousText = ''
    for (const element of textElements) {
      const existingInput = this.#translationInputs.get(element)
      const text = existingInput?.text ?? element.innerText?.trim() ?? ''
      const input = existingInput ?? { text, contextText: previousText }
      this.#translationInputs.set(element, input)
      if (text) previousText = text

      if (!documentState.elements.has(element)) {
        documentState.elements.add(element)
        this.#elementOwners.set(element, documentState)
        this.#observer.observe(element)
      }
    }

    // The iframe load callback runs before paginator layout. Two animation
    // frames provide a deterministic post-render boundary without a timer.
    // Relocation also reconciles explicitly through View.
    this.#scheduleDocumentReconciliation(documentState)
  }

  retainDocuments(documents) {
    const retained = new Set(documents.filter(Boolean))
    for (const doc of this.#documents.keys()) {
      if (!retained.has(doc)) this.unobserveDocument(doc)
    }
  }

  unobserveDocument(doc) {
    const documentState = this.#documents.get(doc)
    if (!documentState) return
    documentState.active = false
    documentState.reconciliationScheduled = false
    for (const element of documentState.elements) {
      this.#observer?.unobserve(element)
      if (this.#elementOwners.get(element) === documentState) {
        this.#elementOwners.delete(element)
      }
    }
    documentState.elements.clear()
    this.#documents.delete(doc)
  }

  async reconcileDocument(doc, visibleRange = undefined) {
    const documentState = this.#documents.get(doc)
    if (documentState && visibleRange !== undefined) {
      documentState.visibleRange = visibleRange
    }
    if (!documentState?.active || this.#translationMode === TranslationMode.OFF) {
      return
    }

    const promises = []
    for (const element of documentState.elements) {
      if (this.#isRelevantElement(element, documentState.visibleRange)) {
        promises.push(this.#reconcileElement(element))
      }
    }
    await Promise.allSettled(promises)
  }

  async reconcileDocuments(
    documents = this.#documents.keys(),
    visibleRange = undefined,
  ) {
    await Promise.allSettled(
      Array.from(documents, doc => this.reconcileDocument(doc, visibleRange)),
    )
  }

  clearTranslations() {
    for (const documentState of this.#documents.values()) {
      documentState.active = false
      for (const element of documentState.elements) {
        for (const translation of this.#translationChildren(element)) {
          translation.remove()
        }
        this.#restoreOriginalText(element)
      }
    }

    this.#observer.disconnect()
    this.#documents.clear()
    this.#elementOwners = new WeakMap()
    this.#translatedElements = new WeakMap()
    this.#translationInputs = new WeakMap()
    this.#inFlightElements = new WeakMap()
    this.#failedElements = new WeakMap()
    this.#initializeObserver()
  }

  #scheduleDocumentReconciliation(documentState) {
    if (documentState.reconciliationScheduled) return
    documentState.reconciliationScheduled = true
    const view = documentState.doc.defaultView ?? window
    const requestFrame = view?.requestAnimationFrame?.bind(view)
      ?? globalThis.requestAnimationFrame?.bind(globalThis)

    const reconcile = () => {
      if (!documentState.active) return
      documentState.reconciliationScheduled = false
      this.reconcileDocument(documentState.doc).catch(error =>
        console.warn('Document translation reconciliation failed:', error)
      )
    }

    if (!requestFrame) {
      queueMicrotask(reconcile)
      return
    }
    requestFrame(() => requestFrame(reconcile))
  }

  #walkTextNodes(root, rejectTags = ['pre', 'code', 'math', 'style', 'script']) {
    const elements = []

    const walk = (node, depth = 0) => {
      if (depth > 15) return

      const children = Array.from(node.children || [])
      for (const child of children) {
        if (rejectTags.includes(child.tagName.toLowerCase())) continue
        if (child.classList.contains('translated-text')) continue

        const hasDirectText = Array.from(child.childNodes).some(node => {
          if (node.nodeType === Node.TEXT_NODE && node.textContent?.trim()) {
            return true
          }
          if (node.nodeType === Node.ELEMENT_NODE && node.tagName === 'SPAN') {
            return true
          }
          return false
        })

        if (child.children.length === 0 && child.textContent?.trim()) {
          elements.push(child)
        } else if (hasDirectText) {
          elements.push(child)
        } else if (child.children.length > 0) {
          walk(child, depth + 1)
        }
      }
    }

    walk(root)
    return elements
  }

  async #reconcileElement(element) {
    if (this.#translationMode === TranslationMode.OFF) return Promise.resolve()
    const documentState = this.#elementOwners.get(element)
    if (!documentState?.active) return Promise.resolve()

    const translated = this.#translatedElements.get(element)
    if (translated) {
      this.#materializeTranslation(element, translated.translatedText)
      return Promise.resolve()
    }

    const existing = this.#inFlightElements.get(element)
    if (existing) return existing

    const previousFailure = this.#failedElements.get(element)
    if (previousFailure && !previousFailure.retryable) return Promise.resolve()

    const input = this.#translationInputs.get(element)
    const text = input?.text ?? element.innerText?.trim()
    if (!text) return Promise.resolve()

    let operation
    operation = (async () => {
      try {
        this.#failedElements.delete(element)
        const translatedText = await translate(text, input?.contextText ?? '')

        // A request belongs only to the element/document generation that
        // started it. A retired chapter completion is discarded.
        if (!documentState.active ||
            this.#elementOwners.get(element) !== documentState) return

        this.#translatedElements.set(element, {
          originalText: text,
          translatedText,
        })
        this.#materializeTranslation(element, translatedText)
      } catch (error) {
        if (documentState.active &&
            this.#elementOwners.get(element) === documentState) {
          this.#failedElements.set(element, {
            retryable: error?.retryable !== false,
          })
        }
        throw error
      } finally {
        if (this.#inFlightElements.get(element) === operation) {
          this.#inFlightElements.delete(element)
        }
      }
    })()
    this.#inFlightElements.set(element, operation)
    return operation
  }

  #translationChildren(element) {
    return Array.from(element.children || [])
      .filter(child => child.classList?.contains('translated-text'))
  }

  #materializeTranslation(element, translatedText) {
    const translations = this.#translationChildren(element)
    let wrapper = translations.shift()
    for (const duplicate of translations) duplicate.remove()

    if (!wrapper) {
      wrapper = element.ownerDocument.createElement('span')
      wrapper.className = 'translated-text'
      wrapper.setAttribute('data-translation-mark', '1')
      wrapper.style.marginTop = '0.2em'
      element.appendChild(wrapper)
    }
    wrapper.textContent = translatedText
    this.#updateElementDisplay(element, wrapper)
  }

  #updateElementDisplay(element, translationWrapper) {
    const data = this.#translatedElements.get(element)
    if (!data) return

    switch (this.#translationMode) {
      case TranslationMode.TRANSLATION_ONLY:
        this.#hideOriginalText(element)
        translationWrapper.style.display = 'block'
        break

      case TranslationMode.ORIGINAL_ONLY:
        this.#restoreOriginalText(element)
        translationWrapper.style.display = 'none'
        break

      case TranslationMode.BILINGUAL:
        this.#restoreOriginalText(element)
        translationWrapper.style.display = 'block'
        break

      case TranslationMode.OFF:
      default:
        this.#restoreOriginalText(element)
        translationWrapper.style.display = 'none'
        break
    }
  }

  #hideOriginalText(element) {
    if (!element.hasAttribute('data-original-visibility')) {
      element.setAttribute('data-original-visibility', 'hidden')

      Array.from(element.childNodes).forEach(node => {
        if (node.nodeType === Node.ELEMENT_NODE) {
          const el = node
          if (!el.classList || !el.classList.contains('translated-text')) {
            if (!el.hasAttribute('data-original-display')) {
              el.setAttribute('data-original-display', el.style.display || 'initial')
              el.style.display = 'none'
            }
          }
        } else if (node.nodeType === Node.TEXT_NODE) {
          if (!node.__originalContent) {
            node.__originalContent = node.textContent
            node.textContent = ''
          }
        }
      })
    }

    element.classList.add('translation-source-hidden')
  }

  #restoreOriginalText(element) {
    if (element.hasAttribute('data-original-visibility')) {
      Array.from(element.childNodes).forEach(node => {
        if (node.nodeType === Node.ELEMENT_NODE) {
          const el = node
          if (!el.classList || !el.classList.contains('translated-text')) {
            if (el.hasAttribute('data-original-display')) {
              const originalDisplay = el.getAttribute('data-original-display')
              el.style.display = originalDisplay === 'initial' ? '' : originalDisplay
              el.removeAttribute('data-original-display')
            }
          }
        } else if (node.nodeType === Node.TEXT_NODE) {
          if (node.__originalContent !== undefined) {
            node.textContent = node.__originalContent
            delete node.__originalContent
          }
        }
      })

      element.removeAttribute('data-original-visibility')
    }

    element.classList.remove('translation-source-hidden')
  }

  #isRelevantElement(element, visibleRange) {
    // Reflowable paginator documents use an iframe whose layout viewport spans
    // the entire columnized chapter. Geometry alone therefore makes every
    // paragraph look visible and can start hundreds of translations at once.
    // The paginator's relocation Range is the authoritative visible region.
    if (visibleRange?.intersectsNode) {
      try {
        return visibleRange.intersectsNode(element)
      } catch (_) {
        return false
      }
    }
    // Before the first relocation there is no reliable reflowable viewport.
    // IntersectionObserver remains active while reconciliation waits for it.
    if (visibleRange === undefined) return false

    // Fixed-layout relocation has no DOM Range. Its one- or two-document
    // spread has a meaningful iframe viewport, so geometry is safe there.
    const rect = element.getBoundingClientRect()
    const view = element.ownerDocument?.defaultView ?? window
    const width = view?.innerWidth ?? window.innerWidth
    const height = view?.innerHeight ?? window.innerHeight
    const margin = 1280
    return rect.right >= -margin && rect.left <= width + margin &&
      rect.bottom >= -margin && rect.top <= height + margin
  }

  #updateTranslationDisplay() {
    for (const documentState of this.#documents.values()) {
      for (const element of documentState.elements) {
        const translated = this.#translatedElements.get(element)
        if (translated) {
          this.#materializeTranslation(element, translated.translatedText)
        } else {
          this.#restoreOriginalText(element)
        }
      }
    }
  }

  destroy() {
    this.clearTranslations()
    this.#observer.disconnect()
    this.#observer = null
  }
}
