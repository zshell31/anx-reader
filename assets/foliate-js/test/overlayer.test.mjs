import assert from 'node:assert/strict'
import test from 'node:test'

class Element {
    style = {}
    children = []
    setAttribute() {}
    append(child) { this.children.push(child) }
    removeChild(child) { this.children.splice(this.children.indexOf(child), 1) }
}
globalThis.document = { createElementNS: () => new Element() }
globalThis.window = { chrome: true }
const { Overlayer } = await import('../src/overlayer.js')
const rect = (left, top, width, height = 20) =>
    ({ left, top, width, height, right: left + width, bottom: top + height })
const range = rects => ({ commonAncestorContainer: {}, getClientRects: () => rects })

test('nested word wins over sentence regardless of insertion/restoration order', () => {
    for (const order of [['word', 'sentence'], ['sentence', 'word']]) {
        const overlay = new Overlayer(document)
        const ranges = {
            word: range([rect(30, 0, 30)]),
            sentence: range([rect(0, 0, 200), rect(0, 30, 200)]),
        }
        for (const key of order) overlay.add(key, ranges[key], Overlayer.highlight)
        assert.equal(overlay.hitTest({ x: 40, y: 10 })[0], 'word')
        assert.equal(overlay.hitTest({ x: 100, y: 10 })[0], 'sentence')
        overlay.redraw()
        assert.equal(overlay.hitTest({ x: 40, y: 10 })[0], 'word')
        overlay.remove('word')
        assert.equal(overlay.hitTest({ x: 40, y: 10 })[0], 'sentence')
    }
})

test('redraw updates both painted geometry and tap targets after text moves', () => {
    const overlay = new Overlayer(document)
    let rects = [rect(0, 0, 100)]
    overlay.add('note', { commonAncestorContainer: {}, getClientRects: () => rects },
        Overlayer.highlight)
    rects = [rect(0, 100, 100)]
    overlay.redraw()
    assert.deepEqual(overlay.hitTest({ x: 10, y: 10 }), [])
    assert.equal(overlay.hitTest({ x: 10, y: 110 })[0], 'note')
})
