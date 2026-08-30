import test from 'node:test'
import assert from 'node:assert/strict'

import {
  annotationForRenderKey,
  annotationForRemoval,
  rendererAnnotationKey,
} from '../src/annotation-renderer-identity.mjs'

test('same-CFI annotations keep independent canonical render keys', () => {
  const first = { id: 'uuid-a', renderKey: 'uuid-a', value: 'same-cfi' }
  const second = { id: 'uuid-b', renderKey: 'uuid-b', value: 'same-cfi' }
  const byId = new Map([[first.id, first], [second.id, second]])

  assert.equal(rendererAnnotationKey(first), 'uuid-a')
  assert.equal(rendererAnnotationKey(second), 'uuid-b')
  assert.equal(annotationForRenderKey(byId, 'uuid-a'), first)
  assert.equal(annotationForRenderKey(byId, 'uuid-b'), second)
})

test('same-CFI removal resolves only the requested canonical UUID', () => {
  const bookmark = { id: 'bookmark-a', type: 'bookmark', value: 'same-cfi' }
  const highlight = { id: 'highlight-b', type: 'highlight', value: 'same-cfi' }
  const byId = new Map([[bookmark.id, bookmark], [highlight.id, highlight]])

  const removed = annotationForRemoval(byId, bookmark.id)
  byId.delete(removed.id)

  assert.equal(removed, bookmark)
  assert.equal(annotationForRemoval(byId, bookmark.id), undefined)
  assert.equal(annotationForRemoval(byId, highlight.id), highlight)
})

test('inverse same-CFI removal leaves bookmark independently addressable', () => {
  const bookmark = { id: 'bookmark-a', type: 'bookmark', value: 'same-cfi' }
  const highlight = { id: 'highlight-b', type: 'highlight', value: 'same-cfi' }
  const byId = new Map([[bookmark.id, bookmark], [highlight.id, highlight]])

  const removed = annotationForRemoval(byId, highlight.id)
  byId.delete(removed.id)

  assert.equal(removed, highlight)
  assert.equal(annotationForRemoval(byId, bookmark.id), bookmark)
})

test('legacy payloads fall back to their navigation value', () => {
  assert.equal(rendererAnnotationKey({ value: 'epubcfi(/6/2)' }),
    'epubcfi(/6/2)')
})
