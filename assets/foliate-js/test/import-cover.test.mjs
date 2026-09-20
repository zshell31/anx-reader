import test from 'node:test'
import assert from 'node:assert/strict'
import { coverDimensions, renderPdfCover, compactCover } from '../src/import-cover.mjs'

test('cover dimensions cap both portrait and landscape without upscaling', () => {
    assert.deepEqual(coverDimensions(2550, 3300), {width: 772, height: 1000, scale: 1000 / 3300})
    assert.equal(coverDimensions(8000, 2000).width, 1000)
    assert.deepEqual(coverDimensions(612, 792), {width: 612, height: 792, scale: 1})
    assert.throws(() => coverDimensions(0, 100))
})

test('PDF cover uses bounded canvas and JPEG regardless of device pixel ratio', async () => {
    const oldDocument = globalThis.document
    const context = {}
    const canvas = { getContext: () => context, toBlob: (callback, type, quality) => {
        assert.equal(type, 'image/jpeg')
        assert.equal(quality, 0.82)
        callback(new Blob(['cover'], {type}))
    }}
    globalThis.document = {createElement: () => canvas}
    try {
        const cover = await renderPdfCover({
            getViewport: ({scale}) => ({width: 2550 * scale, height: 3300 * scale}),
            render: ({canvasContext, viewport, background}) => {
                assert.equal(canvasContext, context)
                assert.equal(viewport.height, 1000)
                assert.equal(background, 'rgb(255,255,255)')
                return {promise: Promise.resolve()}
            },
        })
        assert.equal(canvas.width, 772)
        assert.equal(canvas.height, 1000)
        assert.equal(cover.type, 'image/jpeg')
    } finally { globalThis.document = oldDocument }
})

test('large embedded cover is resized and its bitmap is released', async () => {
    const oldDocument = globalThis.document
    const oldBitmap = globalThis.createImageBitmap
    let closed = false
    const context = {fillRect() {}, drawImage(bitmap, x, y, width, height) {
        assert.equal(width, 1000); assert.equal(height, 500)
    }}
    globalThis.document = {createElement: () => ({getContext: () => context,
        toBlob: (callback, type) => callback(new Blob(['small'], {type}))})}
    globalThis.createImageBitmap = async () => ({width: 6000, height: 3000, close: () => {closed = true}})
    try {
        const result = await compactCover(new Blob([new Uint8Array(300000)]))
        assert.equal(result.type, 'image/jpeg')
        assert.equal(closed, true)
    } finally {globalThis.document = oldDocument; globalThis.createImageBitmap = oldBitmap}
})
