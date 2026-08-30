import test from 'node:test'
import assert from 'node:assert/strict'

import {
  annotationForRenderKey,
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

test('legacy payloads fall back to their navigation value', () => {
  assert.equal(rendererAnnotationKey({ value: 'epubcfi(/6/2)' }),
    'epubcfi(/6/2)')
})
