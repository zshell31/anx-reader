import assert from 'node:assert/strict'
import test from 'node:test'

import {
    buildRangeSentenceContext,
    buildSentenceContext,
} from '../src/sentence-context.mjs'

const contextFor = (source, selectedText, options = {}) => {
    const selectionStart = source.indexOf(selectedText)
    assert.notEqual(selectionStart, -1, `Selection ${JSON.stringify(selectedText)} must exist`)
    return buildSentenceContext({
        source,
        selectionStart,
        selectionEnd: selectionStart + selectedText.length,
        selectedText,
        locale: 'en-US',
        ...options,
    })
}

test('word uses only its containing sentence for annotation context', () => {
    const source = 'Before this. He spent several years talking to incels on obscure online forums. After this.'
    const result = contextFor(source, 'incels')
    assert.equal(result.annotationContext,
        'He spent several years talking to incels on obscure online forums.')
})

test('DOM range uses its semantic paragraph instead of unrelated book body text', () => {
    const block = {}
    const body = {}
    const doc = {
        body,
        createRange: () => {
            let root
            let side
            return {
                selectNodeContents: value => { root = value },
                setEnd: () => { side = 'before' },
                setStart: () => { side = 'after' },
                toString: () => {
                    assert.equal(root, block)
                    return side === 'before' ? 'The selected ' : ' has context.'
                },
            }
        },
    }
    const parentElement = { closest: () => block }
    const textNode = { nodeType: 3, ownerDocument: doc, parentElement }
    const range = {
        startContainer: textNode,
        startOffset: 13,
        endContainer: textNode,
        endOffset: 17,
        toString: () => 'word',
    }

    const result = buildRangeSentenceContext(range, { segmenterFactory: null })
    assert.equal(result.annotationContext, 'The selected word has context.')
    assert.equal(result.lookupContext, 'The selected word has context.')
})

test('multi-word phrase uses its containing sentence', () => {
    const source = 'They met on obscure online forums. Nobody noticed.'
    assert.equal(contextFor(source, 'obscure online forums').annotationContext,
        'They met on obscure online forums.')
})

test('clause uses its containing sentence', () => {
    const source = 'Although it was late, they kept reading until dawn. Then they slept.'
    assert.equal(contextFor(source, 'they kept reading until dawn').annotationContext,
        'Although it was late, they kept reading until dawn.')
})

test('exact full sentence has no annotation context', () => {
    const sentence = 'He spent several years talking to incels on obscure online forums.'
    assert.equal(contextFor(`${sentence} Another sentence.`, sentence).annotationContext, null)
})

test('full sentence without final period has no annotation context', () => {
    const source = 'He spent several years talking to incels on obscure online forums. Another sentence.'
    const selected = 'He spent several years talking to incels on obscure online forums'
    assert.equal(contextFor(source, selected).annotationContext, null)
})

test('full sentence ending with a closing bracket still suppresses a missing period', () => {
    const source = 'He remembered the answer (eventually). Another sentence.'
    const selected = 'He remembered the answer (eventually)'
    assert.equal(contextFor(source, selected).annotationContext, null)
})

test('full sentence inside quotes has no duplicate annotation context', () => {
    const source = '“Stay here!” Then she left.'
    assert.equal(contextFor(source, 'Stay here!').annotationContext, null)
})

test('question sentence is detected', () => {
    const source = 'Where did everyone go? Nobody knew.'
    assert.equal(contextFor(source, 'everyone').annotationContext, 'Where did everyone go?')
})

test('exclamation sentence is detected', () => {
    const source = 'Watch out! The shelf is falling.'
    assert.equal(contextFor(source, 'Watch').annotationContext, 'Watch out!')
})

test('ellipsis sentence is detected', () => {
    const source = 'Perhaps tomorrow… We can wait.'
    assert.equal(contextFor(source, 'tomorrow').annotationContext, 'Perhaps tomorrow…')
})

test('partial selection spanning two sentences uses their smallest containing span', () => {
    const source = 'Alpha begins here. Beta ends there. Gamma follows.'
    assert.equal(contextFor(source, 'begins here. Beta').annotationContext,
        'Alpha begins here. Beta ends there.')
})

test('complete multiple-sentence selection has no annotation context', () => {
    const selected = 'Alpha begins here. Beta ends there.'
    assert.equal(contextFor(`${selected} Gamma follows.`, selected).annotationContext, null)
})

test('leading and trailing selection whitespace is normalized', () => {
    const source = 'Before.   A useful phrase appears here.   After.'
    const result = contextFor(source, '  A useful phrase ')
    assert.equal(result.annotationContext, 'A useful phrase appears here.')
})

test('repeated whitespace and newlines are normalized without changing words', () => {
    const source = 'First sentence.\nThe   useful\nphrase is here.\nLast sentence.'
    const result = contextFor(source, 'useful\nphrase')
    assert.equal(result.annotationContext, 'The useful phrase is here.')
})

test('first sentence lookup has no unavailable previous neighbor', () => {
    const source = 'First sentence has a word. Second sentence follows. Third sentence waits.'
    const result = contextFor(source, 'word')
    assert.equal(result.lookupContext,
        'First sentence has a word. Second sentence follows.')
})

test('last sentence lookup has no unavailable next neighbor', () => {
    const source = 'First sentence. Second sentence has the word.'
    const result = contextFor(source, 'word')
    assert.equal(result.lookupContext,
        'First sentence. Second sentence has the word.')
})

test('lookup context includes previous and next sentence', () => {
    const source = 'Previous sentence. Containing sentence has a word. Next sentence. Outside sentence.'
    const result = contextFor(source, 'word')
    assert.equal(result.lookupContext,
        'Previous sentence. Containing sentence has a word. Next sentence.')
})

test('annotation context excludes lookup neighbors', () => {
    const source = 'Previous sentence. Containing sentence has a word. Next sentence.'
    const result = contextFor(source, 'word')
    assert.equal(result.annotationContext, 'Containing sentence has a word.')
})

test('deterministic fallback handles punctuation and closing brackets', () => {
    const source = 'First sentence. “Is this the target?” (Yes!) Last sentence.'
    const result = contextFor(source, 'target', { segmenterFactory: null })
    assert.equal(result.annotationContext, '“Is this the target?”')
    assert.equal(result.lookupContext,
        'First sentence. “Is this the target?” (Yes!)')
})
