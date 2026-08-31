import assert from 'node:assert/strict'
import test from 'node:test'

import { SelectionGestureOwnership } from '../src/selection-gesture.mjs'
import {
    SelectionSessionMachine,
    SelectionSessionState,
} from '../src/selection-session.mjs'

const point = { pointerId: 7, clientX: 24, clientY: 80 }

const createHarness = ({ actionsVisible = false } = {}) => {
    const doc = {}
    const machine = new SelectionSessionMachine()
    const ownership = new SelectionGestureOwnership()
    const session = machine.select(doc, 'range-a').session
    if (actionsVisible) {
        machine.toggleActions(doc, session.generation, 'range-a')
    }
    const emitted = { actionsRequested: 0, actionsHidden: 0, cleared: 0, clicks: 0 }

    const pointerDown = () => ownership.beginPointer(
        doc, point.pointerId, session.generation, point.clientX, point.clientY)
    const pointerUpInside = () => {
        ownership.endPointer(doc, point.pointerId, point.clientX, point.clientY)
        const current = machine.toggleActions(
            doc, session.generation, machine.current.rangeKey)
        if (current.state === SelectionSessionState.actionsVisible) {
            emitted.actionsRequested++
        } else {
            emitted.actionsHidden++
        }
    }
    const pointerUpOutside = () => {
        ownership.endPointer(doc, point.pointerId, point.clientX, point.clientY)
        if (machine.clear(doc, session.generation)) emitted.cleared++
    }
    const click = (event = point) => {
        if (!ownership.consumeClick(doc, event)) emitted.clicks++
    }

    return {
        doc,
        machine,
        ownership,
        session,
        emitted,
        pointerDown,
        pointerUpInside,
        pointerUpOutside,
        click,
    }
}

test('outside tap clears selected session once and consumes page-zone click', () => {
    const harness = createHarness()

    harness.pointerDown()
    // Android collapses the native Range before pointerup.
    harness.pointerUpOutside()
    harness.click()

    assert.equal(harness.machine.state, SelectionSessionState.idle)
    assert.deepEqual(harness.emitted, {
        actionsRequested: 0,
        actionsHidden: 0,
        cleared: 1,
        clicks: 0,
    })
})

test('inside tap opens actions once and consumes reader click', () => {
    const harness = createHarness()

    harness.pointerDown()
    harness.pointerUpInside()
    harness.click()

    assert.equal(harness.machine.state, SelectionSessionState.actionsVisible)
    assert.equal(harness.emitted.actionsRequested, 1)
    assert.equal(harness.emitted.clicks, 0)
})

test('inside tap hides visible actions once and consumes reader click', () => {
    const harness = createHarness({ actionsVisible: true })

    harness.pointerDown()
    harness.pointerUpInside()
    harness.click()

    assert.equal(harness.machine.state, SelectionSessionState.selected)
    assert.equal(harness.emitted.actionsHidden, 1)
    assert.equal(harness.emitted.clicks, 0)
})

test('outside tap with actions visible clears without emitting reader click', () => {
    const harness = createHarness({ actionsVisible: true })

    harness.pointerDown()
    harness.pointerUpOutside()
    harness.click()

    assert.equal(harness.machine.state, SelectionSessionState.idle)
    assert.equal(harness.emitted.cleared, 1)
    assert.equal(harness.emitted.clicks, 0)
})

test('native Range collapse before click cannot turn the page', () => {
    const harness = createHarness()

    assert.equal(harness.pointerDown(), true)
    harness.pointerUpOutside()
    assert.equal(harness.machine.current, null)
    harness.click()

    assert.equal(harness.emitted.clicks, 0)
})

test('selection-owned suppression is one-shot and next tap emits normally', () => {
    const harness = createHarness()

    harness.pointerDown()
    harness.pointerUpOutside()
    harness.click()
    harness.ownership.beginPointer(
        harness.doc, 8, null, point.clientX, point.clientY)
    harness.click({ pointerId: 8, clientX: point.clientX, clientY: point.clientY })

    assert.equal(harness.emitted.clicks, 1)
})

test('pointer cancellation cannot leave stale click suppression', () => {
    const harness = createHarness()

    harness.pointerDown()
    assert.equal(
        harness.ownership.cancelPointer(harness.doc, point.pointerId),
        true,
    )
    harness.click()

    assert.equal(harness.emitted.clicks, 1)
})

test('document replacement cannot consume a newer document click', () => {
    const harness = createHarness()
    const replacement = {}

    harness.pointerDown()
    harness.ownership.endPointer(
        harness.doc, point.pointerId, point.clientX, point.clientY)
    assert.equal(harness.ownership.invalidateOwner(harness.doc), true)
    assert.equal(harness.ownership.consumeClick(replacement, point), false)
})

test('matching pointer identity tolerates independently rounded click coordinates', () => {
    const harness = createHarness()

    harness.pointerDown()
    harness.ownership.endPointer(
        harness.doc, point.pointerId, point.clientX, point.clientY)
    assert.equal(harness.ownership.consumeClick(harness.doc, {
        ...point,
        clientX: point.clientX + 1,
    }), true)
})

test('synthetic pointer identity falls back to matching coordinates', () => {
    const harness = createHarness()

    harness.pointerDown()
    harness.ownership.endPointer(
        harness.doc, point.pointerId, point.clientX, point.clientY)
    assert.equal(harness.ownership.consumeClick(harness.doc, {
        ...point,
        pointerId: point.pointerId + 1,
    }), true)
})

test('identity and coordinate mismatch is not consumed and a new pointer clears it', () => {
    const harness = createHarness()

    harness.pointerDown()
    harness.ownership.endPointer(
        harness.doc, point.pointerId, point.clientX, point.clientY)
    assert.equal(harness.ownership.consumeClick(harness.doc, {
        ...point,
        pointerId: point.pointerId + 1,
        clientX: point.clientX + 3,
    }), false)
    harness.ownership.beginPointer(harness.doc, 8, null, point.clientX, point.clientY)
    assert.equal(harness.ownership.consumeClick(harness.doc, point), false)
})

test('plain MouseEvent fallback accepts coordinate rounding only', () => {
    const harness = createHarness()

    harness.pointerDown()
    harness.ownership.endPointer(
        harness.doc, point.pointerId, point.clientX, point.clientY)
    assert.equal(harness.ownership.consumeClick(harness.doc, {
        clientX: point.clientX + 1,
        clientY: point.clientY - 1,
    }), true)

    harness.pointerDown()
    harness.ownership.endPointer(
        harness.doc, point.pointerId, point.clientX, point.clientY)
    assert.equal(harness.ownership.consumeClick(harness.doc, {
        clientX: point.clientX + 3,
        clientY: point.clientY,
    }), false)
})
