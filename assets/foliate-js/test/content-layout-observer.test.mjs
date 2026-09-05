import assert from 'node:assert/strict'
import test from 'node:test'
import { observeContentLayout } from '../src/content-layout-observer.mjs'

function fixture() {
    let observer
    const frames = new Map()
    const events = new Map()
    let sequence = 0
    let layouts = 0
    const doc = {
        body: {},
        addEventListener: (type, callback) => events.set(type, callback),
        removeEventListener: type => events.delete(type),
        defaultView: {
            MutationObserver: class {
                constructor(callback) { this.callback = callback; observer = this }
                observe(target, options) { this.target = target; this.options = options }
                disconnect() { this.disconnected = true }
            },
            requestAnimationFrame: callback => { frames.set(++sequence, callback); return sequence },
            cancelAnimationFrame: id => frames.delete(id),
        },
    }
    const stop = observeContentLayout(doc, () => layouts++)
    return { doc, observer, frames, events, stop, get layouts() { return layouts },
        flush() { const callbacks = [...frames.values()]; frames.clear(); callbacks.forEach(cb => cb()) } }
}

test('translation insertion and text arrival refresh layout once without a resize', () => {
    const f = fixture()
    assert.equal(f.observer.target, f.doc.body)
    assert.equal(f.observer.options.subtree, true)
    f.observer.callback([{ type: 'childList', addedNodes: [{}], removedNodes: [] }])
    f.observer.callback([{ type: 'characterData', oldValue: '', target: { data: 'translation' } }])
    assert.equal(f.frames.size, 1)
    assert.equal(f.layouts, 0)
    f.flush()
    assert.equal(f.layouts, 1)
    f.stop()
})

test('unchanged display styles do not produce a reconciliation loop', () => {
    const f = fixture()
    f.observer.callback([{ type: 'attributes', attributeName: 'style',
        oldValue: 'display: block;', target: { getAttribute: () => 'display: block;' } }])
    assert.equal(f.frames.size, 0)
    f.observer.callback([{ type: 'attributes', attributeName: 'style',
        oldValue: 'display: block;', target: { getAttribute: () => 'display: none;' } }])
    f.flush()
    assert.equal(f.layouts, 1)
    f.stop()
})

test('retiring a chapter cancels pending refreshes and removes listeners', () => {
    const f = fixture()
    f.events.get('load')()
    assert.equal(f.frames.size, 1)
    f.stop()
    assert.equal(f.observer.disconnected, true)
    assert.equal(f.events.size, 0)
    assert.equal(f.frames.size, 0)
    f.observer.callback([{ type: 'childList', addedNodes: [{}], removedNodes: [] }])
    f.flush()
    assert.equal(f.layouts, 0)
})
