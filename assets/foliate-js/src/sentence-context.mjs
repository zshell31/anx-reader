const TERMINAL_PUNCTUATION = /[.!?\u2026]/u
const CLOSING_PUNCTUATION = /["'\u2019\u201d\u00bb\u203a)\]\}]/u
const OPENING_PUNCTUATION = /^["'\u2018\u201c\u00ab\u2039(\[\{]+/u
const TERMINAL_ENDING = /[.!?\u2026]+["'\u2019\u201d\u00bb\u203a)\]\}]*$/u
const BARE_TERMINAL_ENDING = /[.!?\u2026]+$/u
const BARE_CLOSING_QUOTES = /["'\u2019\u201d\u00bb\u203a]+$/u
const BARE_CLOSING_PUNCTUATION = /["'\u2019\u201d\u00bb\u203a)\]\}]+$/u

export const normalizeContextWhitespace = text => typeof text === 'string'
    ? text.replace(/\s+/gu, ' ').trim()
    : ''

const fallbackSegments = source => {
    const segments = []
    let start = 0

    for (let index = 0; index < source.length; index += 1) {
        if (!TERMINAL_PUNCTUATION.test(source[index])) continue
        if (source[index] === '.'
            && /\d/u.test(source[index - 1] ?? '')
            && /\d/u.test(source[index + 1] ?? '')) continue

        let end = index + 1
        while (end < source.length && TERMINAL_PUNCTUATION.test(source[end])) end += 1
        while (end < source.length && CLOSING_PUNCTUATION.test(source[end])) end += 1

        if (end < source.length && !/\s/u.test(source[end])) {
            index = end - 1
            continue
        }
        while (end < source.length && /\s/u.test(source[end])) end += 1
        segments.push({ index: start, end, text: source.slice(start, end) })
        start = end
        index = end - 1
    }

    if (start < source.length) {
        segments.push({ index: start, end: source.length, text: source.slice(start) })
    }
    return segments
}

const intlSegments = (source, locale, segmenterFactory) => {
    const segmenter = segmenterFactory(locale)
    const entries = Array.from(segmenter.segment(source))
    return entries.flatMap((entry, index) => {
        const end = entries[index + 1]?.index ?? source.length
        const sentence = { index: entry.index, end, text: entry.segment }
        // Some Intl implementations do not treat a single ellipsis glyph as
        // terminal punctuation. Refine only those entries so normal Intl
        // handling of periods and abbreviations remains authoritative.
        if (!entry.segment.includes('\u2026')) return sentence
        return fallbackSegments(entry.segment).map(segment => ({
            index: entry.index + segment.index,
            end: entry.index + segment.end,
            text: segment.text,
        }))
    })
}

export const segmentSentences = (source, {
    locale,
    segmenterFactory = typeof Intl !== 'undefined' && typeof Intl.Segmenter === 'function'
        ? value => new Intl.Segmenter(value, { granularity: 'sentence' })
        : null,
} = {}) => {
    if (typeof source !== 'string' || !source) return []
    if (segmenterFactory) {
        try {
            return intlSegments(source, locale, segmenterFactory)
        } catch (error) {
            console.warn('Sentence segmentation fell back after Intl.Segmenter failed', error)
        }
    }
    return fallbackSegments(source)
}

const meaningfulBounds = (source, start, end) => {
    let meaningfulStart = Math.max(0, Math.min(source.length, start))
    let meaningfulEnd = Math.max(meaningfulStart, Math.min(source.length, end))
    while (meaningfulStart < meaningfulEnd && /\s/u.test(source[meaningfulStart])) meaningfulStart += 1
    while (meaningfulEnd > meaningfulStart && /\s/u.test(source[meaningfulEnd - 1])) meaningfulEnd -= 1
    return { start: meaningfulStart, end: meaningfulEnd }
}

const comparisonText = text => {
    const normalized = normalizeContextWhitespace(text)
    const withoutOpening = normalized.replace(OPENING_PUNCTUATION, '')
    const removedOpening = withoutOpening !== normalized
    return withoutOpening
        .replace(TERMINAL_ENDING, '')
        .replace(BARE_TERMINAL_ENDING, '')
        .replace(removedOpening ? BARE_CLOSING_PUNCTUATION : BARE_CLOSING_QUOTES, '')
        .replace(BARE_TERMINAL_ENDING, '')
        .trim()
}

const contextAddsMeaning = (context, selectedText) => {
    const normalizedContext = normalizeContextWhitespace(context)
    const normalizedSelection = normalizeContextWhitespace(selectedText)
    if (!normalizedContext || !normalizedSelection) return false
    return comparisonText(normalizedContext) !== comparisonText(normalizedSelection)
}

/**
 * Builds compact persisted and wider transient context for a source range.
 * Offsets refer to UTF-16 positions in `source`, matching DOM Range offsets.
 */
export const buildSentenceContext = ({
    source,
    selectionStart,
    selectionEnd,
    selectedText = source?.slice(selectionStart, selectionEnd),
    locale,
    segmenterFactory,
}) => {
    if (typeof source !== 'string') {
        return { annotationContext: null, lookupContext: null }
    }

    const selectedBounds = meaningfulBounds(source, selectionStart, selectionEnd)
    if (selectedBounds.start === selectedBounds.end) {
        return { annotationContext: null, lookupContext: null }
    }

    const sentences = segmentSentences(source, { locale, segmenterFactory })
        .filter(sentence => normalizeContextWhitespace(sentence.text))
    const first = sentences.findIndex(sentence => sentence.end > selectedBounds.start)
    let last = -1
    for (let index = sentences.length - 1; index >= 0; index -= 1) {
        if (sentences[index].index < selectedBounds.end) {
            last = index
            break
        }
    }
    if (first < 0 || last < first) {
        return { annotationContext: null, lookupContext: null }
    }

    const containingText = normalizeContextWhitespace(
        source.slice(sentences[first].index, sentences[last].end),
    )
    const lookupStart = Math.max(0, first - 1)
    const lookupEnd = Math.min(sentences.length - 1, last + 1)
    const lookupText = normalizeContextWhitespace(
        source.slice(sentences[lookupStart].index, sentences[lookupEnd].end),
    )

    return {
        annotationContext: contextAddsMeaning(containingText, selectedText)
            ? containingText
            : null,
        lookupContext: lookupText || null,
    }
}

export const buildRangeSentenceContext = (range, options = {}) => {
    if (!range) return { annotationContext: null, lookupContext: null }
    const doc = range.startContainer?.ownerDocument
        ?? (range.startContainer?.nodeType === 9 ? range.startContainer : null)
    const root = doc?.body ?? doc?.documentElement
    if (!doc || !root) return { annotationContext: null, lookupContext: null }

    const beforeRange = doc.createRange()
    beforeRange.selectNodeContents(root)
    beforeRange.setEnd(range.startContainer, range.startOffset)
    const afterRange = doc.createRange()
    afterRange.selectNodeContents(root)
    afterRange.setStart(range.endContainer, range.endOffset)

    const before = beforeRange.toString()
    const selectedText = range.toString()
    const source = before + selectedText + afterRange.toString()
    return buildSentenceContext({
        source,
        selectionStart: before.length,
        selectionEnd: before.length + selectedText.length,
        selectedText,
        ...options,
    })
}
