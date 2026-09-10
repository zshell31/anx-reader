import assert from 'node:assert/strict'
import test from 'node:test'
import {readFileSync} from 'node:fs'

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

test('saved highlights have 10px padding and direct hits take priority', () => {
    const overlay = new Overlayer(document)
    overlay.add('first', range([rect(20, 20, 40)]), Overlayer.highlight)
    overlay.add('second', range([rect(20, 45, 40)]), Overlayer.highlight)
    assert.equal(overlay.hitTest({ x: 10, y: 10 })[0], 'first')
    assert.deepEqual(overlay.hitTest({ x: 9, y: 20 }), [])
    assert.equal(overlay.hitTest({ x: 30, y: 46 })[0], 'second')
    assert.equal(overlay.hitTest({ x: 30, y: 44 })[0], 'second')
})

 test('equal ranges use canonical creation time then ID in either draw order', () => {
    for (const order of [['a', 'b', 'old'], ['old', 'b', 'a']]) {
        const overlay = new Overlayer(document)
        for (const id of order) overlay.add(id, range([rect(0, 0, 40)]), Overlayer.highlight,
            {createdAt:id === 'old' ? '2026-09-09T00:00:00.000Z' : '2026-09-10T00:00:00.000Z', annotationId:id})
        assert.equal(overlay.hitTest({x:10,y:10})[0], 'old')
        overlay.remove('old')
        assert.equal(overlay.hitTest({x:10,y:10})[0], 'a')
    }
})

test('RFC shared overlap fixture resolves the narrowest annotation', () => {
    const fixture = JSON.parse(readFileSync(new URL('../../../protocol/notes-rfc/fixtures/editor/states.json', import.meta.url), 'utf8'))
    const overlay = new Overlayer(document)
    for (const r of fixture.overlap.ranges) overlay.add(r.id, range([rect(r.start, 0, r.end-r.start)]), Overlayer.highlight, {createdAt:r.createdAt, annotationId:r.id})
    assert.equal(overlay.hitTest({x:fixture.overlap.point,y:10})[0], fixture.overlap.expected)
})
