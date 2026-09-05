import assert from 'node:assert/strict'
import test from 'node:test'

globalThis.Node = { ELEMENT_NODE: 1, TEXT_NODE: 3 }
globalThis.window = {
  innerWidth: 800,
  innerHeight: 600,
  reader: null,
}
const windowListeners = new Map()
window.addEventListener = (type, listener) => {
  const listeners = windowListeners.get(type) ?? new Set()
  listeners.add(listener)
  windowListeners.set(type, listeners)
}
window.removeEventListener = (type, listener) =>
  windowListeners.get(type)?.delete(listener)
const dispatchWindowEvent = type => {
  for (const listener of windowListeners.get(type) ?? []) listener()
}

const observers = []
class FakeIntersectionObserver {
  constructor(callback) {
    this.callback = callback
    this.targets = new Set()
    this.unobserved = new Set()
    observers.push(this)
  }
  observe(element) { this.targets.add(element) }
  unobserve(element) {
    this.targets.delete(element)
    this.unobserved.add(element)
  }
  disconnect() { this.targets.clear() }
  trigger(element, isIntersecting = true) {
    this.callback([{ target: element, isIntersecting }])
  }
}
globalThis.IntersectionObserver = FakeIntersectionObserver

const { Translator, TranslationMode } = await import('../src/translator.js')

class FakeClassList {
  #values = new Set()
  add(value) { this.#values.add(value) }
  remove(value) { this.#values.delete(value) }
  contains(value) { return this.#values.has(value) }
  set(value) {
    this.#values = new Set(value.split(/\s+/).filter(Boolean))
  }
  toString() { return Array.from(this.#values).join(' ') }
}

class FakeTextNode {
  constructor(text) {
    this.nodeType = Node.TEXT_NODE
    this.textContent = text
    this.parentNode = null
  }
}

class FakeElement {
  constructor(tagName, ownerDocument, text = '') {
    this.nodeType = Node.ELEMENT_NODE
    this.tagName = tagName.toUpperCase()
    this.ownerDocument = ownerDocument
    this.parentNode = null
    this.childNodes = []
    this.children = []
    this.classList = new FakeClassList()
    this.style = {}
    this.attributes = new Map()
    this.rect = { top: 10, bottom: 30, left: 10, right: 300 }
    if (text) this.appendChild(new FakeTextNode(text))
  }
  get className() { return this.classList.toString() }
  set className(value) { this.classList.set(value) }
  get textContent() {
    return this.childNodes.map(node => node.textContent).join('')
  }
  set textContent(value) {
    for (const child of this.childNodes) child.parentNode = null
    this.childNodes = []
    this.children = []
    if (value !== '') this.appendChild(new FakeTextNode(value))
  }
  get innerText() { return this.textContent }
  appendChild(node) {
    node.remove?.()
    node.parentNode = this
    this.childNodes.push(node)
    if (node.nodeType === Node.ELEMENT_NODE) this.children.push(node)
    return node
  }
  remove() {
    if (!this.parentNode) return
    const parent = this.parentNode
    parent.childNodes = parent.childNodes.filter(node => node !== this)
    parent.children = parent.children.filter(node => node !== this)
    this.parentNode = null
  }
  setAttribute(name, value) { this.attributes.set(name, String(value)) }
  getAttribute(name) { return this.attributes.get(name) ?? null }
  hasAttribute(name) { return this.attributes.has(name) }
  removeAttribute(name) { this.attributes.delete(name) }
  getBoundingClientRect() { return this.rect }
  querySelectorAll(selector) {
    if (selector !== '.translated-text') return []
    const found = []
    const visit = element => {
      for (const child of element.children) {
        if (child.classList.contains('translated-text')) found.push(child)
        visit(child)
      }
    }
    visit(this)
    return found
  }
}

class FakeView {
  constructor() {
    this.innerWidth = 800
    this.innerHeight = 600
    this.frames = []
  }
  requestAnimationFrame(callback) {
    this.frames.push(callback)
    return this.frames.length
  }
  flushFrame() {
    const frames = this.frames.splice(0)
    for (const frame of frames) frame()
  }
}

const makeDocument = (...texts) => {
  const view = new FakeView()
  const doc = {
    defaultView: view,
    createElement: tagName => new FakeElement(tagName, doc),
  }
  doc.body = new FakeElement('body', doc)
  doc.documentElement = doc.body
  const paragraphs = texts.map(text => {
    const paragraph = new FakeElement('p', doc, text)
    doc.body.appendChild(paragraph)
    return paragraph
  })
  return { doc, paragraphs, view }
}

const wrappers = element => element.children
  .filter(child => child.classList.contains('translated-text'))
const visibleRange = (...elements) => ({
  intersectsNode: element => elements.includes(element),
})
const relocate = (translator, chapter, ...elements) =>
  translator.reconcileDocument(
    chapter.doc,
    visibleRange(...(elements.length > 0 ? elements : chapter.paragraphs)),
  )
const relocateWithPrefetch = (translator, chapter, current, next) =>
  translator.reconcileDocument(
    chapter.doc,
    visibleRange(current),
    visibleRange(next),
  )

const settle = () => new Promise(resolve => setImmediate(resolve))
const flushLayout = async view => {
  view.flushFrame()
  view.flushFrame()
  await settle()
}

const setup = (
  handler = async (_name, text) => `translated:${text}`,
  options = undefined,
) => {
  observers.length = 0
  windowListeners.clear()
  const calls = []
  window.flutter_inappwebview = {
    callHandler: (...args) => {
      calls.push(args)
      return handler(...args)
    },
  }
  const translator = new Translator(options)
  return { translator, calls, observer: observers.at(-1) }
}

test('already-enabled bilingual mode reconciles every newly observed chapter', async () => {
  const { translator, calls } = setup()
  await translator.setTranslationMode(TranslationMode.BILINGUAL)
  const chapterA = makeDocument('A')
  translator.observeDocument(chapterA.doc)
  await relocate(translator, chapterA)
  const chapterB = makeDocument('B1', 'B2')
  translator.observeDocument(chapterB.doc)
  await relocate(translator, chapterB)

  assert.deepEqual(calls.map(([, text, context]) => [text, context]), [
    ['A', ''],
    ['B1', ''],
    ['B2', 'B1'],
  ])
  assert.equal(wrappers(chapterB.paragraphs[0]).length, 1)
  assert.equal(wrappers(chapterB.paragraphs[1]).length, 1)
})

test('document reconciliation repairs a missed initial observer callback', async () => {
  const { translator, calls } = setup()
  await translator.setTranslationMode(TranslationMode.BILINGUAL)
  const chapter = makeDocument('visible paragraph')
  translator.observeDocument(chapter.doc)
  await relocate(translator, chapter)

  assert.equal(calls.length, 1)
  assert.equal(wrappers(chapter.paragraphs[0]).length, 1)
})

test('observer and reconciliation join one in-flight element operation', async () => {
  let complete
  const pending = new Promise(resolve => { complete = resolve })
  const { translator, calls, observer } = setup(() => pending)
  await translator.setTranslationMode(TranslationMode.BILINGUAL)
  const chapter = makeDocument('deduplicated')
  translator.observeDocument(chapter.doc)
  observer.trigger(chapter.paragraphs[0])
  const reconciliation = relocate(translator, chapter)

  assert.equal(calls.length, 1)
  complete('shared translation')
  await reconciliation
  assert.equal(calls.length, 1)
  assert.equal(wrappers(chapter.paragraphs[0]).length, 1)
})

test('immediately resolved cached result materializes exactly one wrapper', async () => {
  const { translator, calls, observer } = setup()
  await translator.setTranslationMode(TranslationMode.BILINGUAL)
  const chapter = makeDocument('cached')
  translator.observeDocument(chapter.doc)
  observer.trigger(chapter.paragraphs[0])
  await relocate(translator, chapter)

  assert.equal(calls.length, 1)
  assert.equal(wrappers(chapter.paragraphs[0]).length, 1)
})

test('slow result materializes after completion', async () => {
  let complete
  const pending = new Promise(resolve => { complete = resolve })
  const { translator, observer } = setup(() => pending)
  await translator.setTranslationMode(TranslationMode.BILINGUAL)
  const chapter = makeDocument('slow')
  translator.observeDocument(chapter.doc)
  observer.trigger(chapter.paragraphs[0])
  assert.equal(wrappers(chapter.paragraphs[0]).length, 0)

  complete('eventual translation')
  await settle()
  assert.equal(wrappers(chapter.paragraphs[0]).length, 1)
})

test('layout reconciliation preserves already materialized translation nodes', async () => {
  const { translator, calls } = setup()
  await translator.setTranslationMode(TranslationMode.BILINGUAL)
  const chapter = makeDocument('stable translated paragraph')
  translator.observeDocument(chapter.doc)
  await relocate(translator, chapter)
  const wrapper = wrappers(chapter.paragraphs[0])[0]
  const textNode = wrapper.childNodes[0]
  await relocate(translator, chapter)
  await relocate(translator, chapter)
  assert.equal(wrapper.childNodes[0], textNode)
  assert.equal(calls.length, 1)
})

test('reconciliation restores a removed wrapper without another bridge call', async () => {
  const { translator, calls } = setup()
  await translator.setTranslationMode(TranslationMode.BILINGUAL)
  const chapter = makeDocument('repair')
  translator.observeDocument(chapter.doc)
  await relocate(translator, chapter)
  wrappers(chapter.paragraphs[0])[0].remove()

  await translator.reconcileDocument(chapter.doc)
  assert.equal(calls.length, 1)
  assert.equal(wrappers(chapter.paragraphs[0]).length, 1)
})

test('late completion from a retired chapter cannot affect its replacement', async () => {
  let completeA
  const pendingA = new Promise(resolve => { completeA = resolve })
  const { translator, observer } = setup(
    async (_name, text) => text === 'A' ? pendingA : `translated:${text}`,
  )
  await translator.setTranslationMode(TranslationMode.BILINGUAL)
  const chapterA = makeDocument('A')
  translator.observeDocument(chapterA.doc)
  observer.trigger(chapterA.paragraphs[0])

  const chapterB = makeDocument('B')
  translator.observeDocument(chapterB.doc)
  translator.retainDocuments([chapterB.doc])
  await relocate(translator, chapterB)
  completeA('late A')
  await settle()

  assert.equal(wrappers(chapterA.paragraphs[0]).length, 0)
  assert.equal(wrappers(chapterB.paragraphs[0]).length, 1)
  assert.equal(wrappers(chapterB.paragraphs[0])[0].textContent, 'translated:B')
})

test('a transient failure remains retryable on later reconciliation', async () => {
  let attempts = 0
  const { translator, calls } = setup(async () => {
    attempts++
    if (attempts === 1) throw new Error('temporary transport failure')
    return 'recovered'
  })
  await translator.setTranslationMode(TranslationMode.BILINGUAL)
  const chapter = makeDocument('retry')
  translator.observeDocument(chapter.doc)
  await relocate(translator, chapter)
  assert.equal(wrappers(chapter.paragraphs[0]).length, 0)

  await translator.reconcileDocument(chapter.doc)
  assert.equal(calls.length, 2)
  assert.equal(wrappers(chapter.paragraphs[0]).length, 1)
})

test('online lifecycle retries a settled transient failure', async () => {
  let attempts = 0
  const { translator, calls } = setup(async () => {
    attempts++
    if (attempts === 1) throw new Error('offline')
    return 'online translation'
  })
  await translator.setTranslationMode(TranslationMode.BILINGUAL)
  const chapter = makeDocument('retry online')
  translator.observeDocument(chapter.doc)
  await relocate(translator, chapter)
  assert.equal(wrappers(chapter.paragraphs[0]).length, 0)

  dispatchWindowEvent('online')
  await settle()
  assert.equal(calls.length, 2)
  assert.equal(wrappers(chapter.paragraphs[0])[0].textContent,
    'online translation')
})

test('a permanent authentication failure is not retried on every relocation', async () => {
  const { translator, calls } = setup(async () => 'Authentication failed: bad key')
  await translator.setTranslationMode(TranslationMode.BILINGUAL)
  const chapter = makeDocument('permanent failure')
  translator.observeDocument(chapter.doc)
  await relocate(translator, chapter)

  await translator.reconcileDocument(chapter.doc)
  await translator.reconcileDocument(chapter.doc)
  assert.equal(calls.length, 1)
  assert.equal(wrappers(chapter.paragraphs[0]).length, 0)
})

test('all display modes preserve their existing source/wrapper semantics', async () => {
  const { translator, calls } = setup()
  const chapter = makeDocument('mode source')
  const paragraph = chapter.paragraphs[0]
  translator.observeDocument(chapter.doc)
  await relocate(translator, chapter)
  await flushLayout(chapter.view)
  assert.equal(calls.length, 0)
  assert.equal(wrappers(paragraph).length, 0)

  await translator.setTranslationMode(TranslationMode.ORIGINAL_ONLY)
  assert.equal(wrappers(paragraph)[0].style.display, 'none')
  assert.equal(paragraph.hasAttribute('data-original-visibility'), false)

  await translator.setTranslationMode(TranslationMode.TRANSLATION_ONLY)
  assert.equal(wrappers(paragraph)[0].style.display, 'block')
  assert.equal(paragraph.hasAttribute('data-original-visibility'), true)

  await translator.setTranslationMode(TranslationMode.BILINGUAL)
  assert.equal(wrappers(paragraph)[0].style.display, 'block')
  assert.equal(paragraph.hasAttribute('data-original-visibility'), false)

  await translator.setTranslationMode(TranslationMode.OFF)
  assert.equal(wrappers(paragraph)[0].style.display, 'none')
  assert.equal(paragraph.hasAttribute('data-original-visibility'), false)
  assert.equal(calls.length, 1)
})

test('retired document elements are unobserved and no longer reconciled', async () => {
  const { translator, calls, observer } = setup()
  const chapterA = makeDocument('A')
  const chapterB = makeDocument('B')
  translator.observeDocument(chapterA.doc)
  translator.observeDocument(chapterB.doc)
  translator.retainDocuments([chapterB.doc])
  await relocate(translator, chapterB)

  assert.equal(observer.targets.has(chapterA.paragraphs[0]), false)
  assert.equal(observer.unobserved.has(chapterA.paragraphs[0]), true)
  await translator.setTranslationMode(TranslationMode.BILINGUAL)
  await translator.reconcileDocument(chapterA.doc)
  assert.deepEqual(calls.map(([, text]) => text), ['B'])
})

test('reconciliation translates current and next paginator ranges only', async () => {
  const { translator, calls } = setup()
  await translator.setTranslationMode(TranslationMode.BILINGUAL)
  const chapter = makeDocument('visible', 'next page', 'far away')
  translator.observeDocument(chapter.doc)

  await relocateWithPrefetch(
    translator,
    chapter,
    chapter.paragraphs[0],
    chapter.paragraphs[1],
  )
  assert.deepEqual(calls.map(([, text]) => text), ['visible', 'next page'])
  assert.equal(wrappers(chapter.paragraphs[1]).length, 1)
  assert.equal(wrappers(chapter.paragraphs[2]).length, 0)

  await relocateWithPrefetch(
    translator,
    chapter,
    chapter.paragraphs[1],
    chapter.paragraphs[2],
  )
  assert.deepEqual(
    calls.map(([, text]) => text),
    ['visible', 'next page', 'far away'],
  )
  assert.equal(wrappers(chapter.paragraphs[2]).length, 1)
})

test('translation queue bounds bridge concurrency', async () => {
  const completions = []
  let active = 0
  let maximumActive = 0
  const { translator, calls } = setup((_name, text) => {
    active++
    maximumActive = Math.max(maximumActive, active)
    return new Promise(resolve => completions.push(value => {
      active--
      resolve(value)
    }))
  })
  await translator.setTranslationMode(TranslationMode.BILINGUAL)
  const chapter = makeDocument('A', 'B', 'C', 'D', 'E', 'F')
  translator.observeDocument(chapter.doc)

  const reconciliation = translator.reconcileDocument(
    chapter.doc,
    visibleRange(...chapter.paragraphs.slice(0, 3)),
    visibleRange(...chapter.paragraphs.slice(3)),
  )
  assert.equal(calls.length, 3)
  while (completions.length > 0 || calls.length < chapter.paragraphs.length) {
    completions.shift()?.('translated')
    await settle()
  }
  await reconciliation

  assert.equal(maximumActive, 3)
  assert.equal(calls.length, 6)
})

test('new current-page work precedes queued prefetch', async () => {
  const completions = new Map()
  const { translator, calls } = setup(
    (_name, text) => new Promise(resolve => completions.set(text, resolve)),
    { maxConcurrentTranslations: 1 },
  )
  await translator.setTranslationMode(TranslationMode.BILINGUAL)
  const chapter = makeDocument('blocking', 'new current', 'prefetch')
  translator.observeDocument(chapter.doc)

  const first = translator.reconcileDocument(
    chapter.doc,
    visibleRange(chapter.paragraphs[0]),
    visibleRange(chapter.paragraphs[2]),
  )
  const second = translator.reconcileDocument(
    chapter.doc,
    visibleRange(chapter.paragraphs[1]),
    visibleRange(chapter.paragraphs[2]),
  )
  assert.deepEqual(calls.map(([, text]) => text), ['blocking'])

  completions.get('blocking')('done')
  await settle()
  assert.deepEqual(calls.map(([, text]) => text), ['blocking', 'new current'])
  completions.get('new current')('done')
  await settle()
  assert.deepEqual(calls.map(([, text]) => text),
    ['blocking', 'new current', 'prefetch'])
  completions.get('prefetch')('done')
  await Promise.all([first, second])
})

test('queued work from a retired chapter never reaches the bridge', async () => {
  const completions = new Map()
  const { translator, calls } = setup(
    (_name, text) => new Promise(resolve => completions.set(text, resolve)),
    { maxConcurrentTranslations: 1 },
  )
  await translator.setTranslationMode(TranslationMode.BILINGUAL)
  const retired = makeDocument('running old', 'queued old')
  translator.observeDocument(retired.doc)
  const oldReconciliation = relocate(translator, retired)

  const current = makeDocument('current chapter')
  translator.observeDocument(current.doc)
  translator.retainDocuments([current.doc])
  const currentReconciliation = relocate(translator, current)
  assert.deepEqual(calls.map(([, text]) => text), ['running old'])

  completions.get('running old')('stale')
  await settle()
  assert.deepEqual(calls.map(([, text]) => text),
    ['running old', 'current chapter'])
  completions.get('current chapter')('translated')
  await Promise.all([oldReconciliation, currentReconciliation])
  assert.equal(wrappers(retired.paragraphs[0]).length, 0)
  assert.equal(wrappers(retired.paragraphs[1]).length, 0)
  assert.equal(wrappers(current.paragraphs[0]).length, 1)
})
