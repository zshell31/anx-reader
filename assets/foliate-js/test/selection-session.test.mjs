import assert from 'node:assert/strict'
import test from 'node:test'

import {
    SelectionSessionMachine,
    SelectionSessionState,
} from '../src/selection-session.mjs'

test('new and repeatedly reported selections keep actions hidden', () => {
    const machine = new SelectionSessionMachine()
    const doc = {}

    const created = machine.select(doc, 'range-a')
    assert.equal(created.session.state, SelectionSessionState.selected)
    assert.equal(machine.select(doc, 'range-a'), null)
    assert.equal(machine.state, SelectionSessionState.selected)
})

test('inside taps toggle actions without ending the selection', () => {
    const machine = new SelectionSessionMachine()
    const doc = {}
    const session = machine.select(doc, 'range-a').session

    assert.equal(
        machine.toggleActions(doc, session.generation, 'range-a').state,
        SelectionSessionState.actionsVisible,
    )
    assert.equal(
        machine.toggleActions(doc, session.generation, 'range-a').state,
        SelectionSessionState.selected,
    )
    assert.equal(machine.current.generation, session.generation)
})

test('range modification hides actions while preserving the generation', () => {
    const machine = new SelectionSessionMachine()
    const doc = {}
    const session = machine.select(doc, 'range-a').session
    machine.toggleActions(doc, session.generation, 'range-a')

    const changed = machine.select(doc, 'range-b')
    assert.equal(changed.hidActions, true)
    assert.equal(changed.session.state, SelectionSessionState.selected)
    assert.equal(changed.session.generation, session.generation)
})

test('outside clear ends the session and invalidates matching callbacks', () => {
    const machine = new SelectionSessionMachine()
    const doc = {}
    const session = machine.select(doc, 'range-a').session
    machine.toggleActions(doc, session.generation, 'range-a')

    const ended = machine.clear(doc, session.generation)
    assert.equal(ended.generation, session.generation)
    assert.equal(machine.state, SelectionSessionState.idle)
    assert.equal(
        machine.toggleActions(doc, session.generation, 'range-a'),
        null,
    )
})

test('stale callbacks cannot change or clear a replacement session', () => {
    const machine = new SelectionSessionMachine()
    const firstDoc = {}
    const secondDoc = {}
    const first = machine.select(firstDoc, 'range-a').session
    const second = machine.select(secondDoc, 'range-b').session

    assert.ok(second.generation > first.generation)
    assert.equal(machine.toggleActions(firstDoc, first.generation, 'range-a'), null)
    assert.equal(machine.hideActions(first.generation), null)
    assert.equal(machine.clear(firstDoc, first.generation), null)
    assert.deepEqual(machine.current, second)
})

test('rapid replacement cannot resurrect UI from an earlier generation', () => {
    const machine = new SelectionSessionMachine()
    const firstDoc = {}
    const secondDoc = {}
    const first = machine.select(firstDoc, 'range-a').session
    machine.toggleActions(firstDoc, first.generation, 'range-a')
    const second = machine.select(secondDoc, 'range-b').session

    assert.equal(machine.hideActions(first.generation), null)
    assert.equal(machine.current.generation, second.generation)
    assert.equal(machine.current.state, SelectionSessionState.selected)
})

test('a stale callback cannot affect a newer generation in the same document', () => {
    const machine = new SelectionSessionMachine()
    const doc = {}
    const first = machine.select(doc, 'range-a').session
    machine.clear(doc, first.generation)
    const second = machine.select(doc, 'range-b').session

    assert.ok(second.generation > first.generation)
    assert.equal(machine.toggleActions(doc, first.generation, 'range-a'), null)
    assert.equal(machine.clear(doc, first.generation), null)
    assert.deepEqual(machine.current, second)
})
