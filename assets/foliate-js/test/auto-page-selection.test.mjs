import assert from 'node:assert/strict'
import test from 'node:test'

import { AutoPageSelectionCoordinator } from '../src/auto-page-selection.mjs'
import {
    SelectionSessionMachine,
    SelectionSessionState,
} from '../src/selection-session.mjs'

class FakeTimers {
    #nextId = 0
    #tasks = new Map()

    setTimer = (callback, delay) => {
        const id = ++this.#nextId
        this.#tasks.set(id, { callback, delay })
        return id
    }

    clearTimer = id => this.#tasks.delete(id)

    get size() {
        return this.#tasks.size
    }

    firstId() {
        return this.#tasks.keys().next().value
    }

    async run(id = this.firstId()) {
        const task = this.#tasks.get(id)
        if (!task) return
        this.#tasks.delete(id)
        await task.callback()
    }
}

const setUp = (options = {}) => {
    const machine = new SelectionSessionMachine()
    const timers = new FakeTimers()
    const coordinator = new AutoPageSelectionCoordinator(machine, {
        setTimer: timers.setTimer,
        clearTimer: timers.clearTimer,
        advanceDelayMs: 10,
        recheckInitialDelayMs: 5,
        recheckIntervalMs: 5,
        maxRecheckAttempts: 3,
        ...options,
    })
    return { machine, timers, coordinator }
}

test('page boundary schedules one advance and ignores duplicate reports', async () => {
    const { machine, timers, coordinator } = setUp()
    const doc = {}
    const session = machine.select(doc, 'range-a').session
    let advances = 0
    const request = {
        owner: doc,
        generation: session.generation,
        pageKey: 'page-1',
        advance: async () => { advances += 1 },
        recheck: () => {},
    }

    assert.equal(coordinator.scheduleAdvance(request), true)
    assert.equal(coordinator.scheduleAdvance(request), false)
    assert.equal(timers.size, 1)
    await timers.run()
    assert.equal(advances, 1)
    assert.equal(coordinator.scheduleAdvance(request), false)
})

test('clearing selection before the delay prevents navigation', async () => {
    const { machine, timers, coordinator } = setUp()
    const doc = {}
    const session = machine.select(doc, 'range-a').session
    let advances = 0
    coordinator.scheduleAdvance({
        owner: doc,
        generation: session.generation,
        pageKey: 'page-1',
        advance: async () => { advances += 1 },
        recheck: () => {},
    })
    const staleTimer = timers.firstId()

    machine.clear(doc, session.generation)
    coordinator.end(doc, session.generation)
    await timers.run(staleTimer)
    assert.equal(advances, 0)
})

test('a replacement selection generation invalidates the old delayed advance', async () => {
    const { machine, timers, coordinator } = setUp()
    const doc = {}
    const first = machine.select(doc, 'range-a').session
    let advances = 0
    coordinator.scheduleAdvance({
        owner: doc,
        generation: first.generation,
        pageKey: 'page-1',
        advance: async () => { advances += 1 },
        recheck: () => {},
    })
    const staleTimer = timers.firstId()

    machine.clear(doc, first.generation)
    const second = machine.select(doc, 'range-b').session
    coordinator.observePage(doc, second.generation, 'page-1')
    await timers.run(staleTimer)

    assert.ok(second.generation > first.generation)
    assert.equal(advances, 0)
})

test('stale post-next recheck cannot affect a replacement generation', async () => {
    const { machine, timers, coordinator } = setUp()
    const doc = {}
    const first = machine.select(doc, 'range-a').session
    let rechecks = 0
    coordinator.scheduleAdvance({
        owner: doc,
        generation: first.generation,
        pageKey: 'page-1',
        advance: async () => {},
        recheck: () => { rechecks += 1 },
    })
    await timers.run()
    const staleRecheck = timers.firstId()

    machine.clear(doc, first.generation)
    const second = machine.select(doc, 'range-b').session
    coordinator.observePage(doc, second.generation, 'page-2')
    await timers.run(staleRecheck)

    assert.equal(rechecks, 0)
    assert.equal(machine.current.generation, second.generation)
})

test('an in-flight advance cannot schedule rechecks after its generation ends', async () => {
    const { machine, timers, coordinator } = setUp()
    const doc = {}
    const first = machine.select(doc, 'range-a').session
    let resolveAdvance
    const advanceFinished = new Promise(resolve => { resolveAdvance = resolve })
    let afterAdvances = 0
    let rechecks = 0
    coordinator.scheduleAdvance({
        owner: doc,
        generation: first.generation,
        pageKey: 'page-1',
        advance: () => advanceFinished,
        afterAdvance: () => { afterAdvances += 1 },
        recheck: () => { rechecks += 1 },
    })

    const runningAdvance = timers.run()
    machine.clear(doc, first.generation)
    coordinator.end(doc, first.generation)
    const second = machine.select(doc, 'range-b').session
    coordinator.observePage(doc, second.generation, 'page-2')
    resolveAdvance()
    await runningAdvance

    assert.equal(afterAdvances, 0)
    assert.equal(rechecks, 0)
    assert.equal(timers.size, 0)
    assert.equal(coordinator.snapshot.generation, second.generation)
})

test('clearing after navigation but before recheck stops continuation', async () => {
    const { machine, timers, coordinator } = setUp()
    const doc = {}
    const session = machine.select(doc, 'range-a').session
    let rechecks = 0
    coordinator.scheduleAdvance({
        owner: doc,
        generation: session.generation,
        pageKey: 'page-1',
        advance: async () => {},
        recheck: () => { rechecks += 1 },
    })
    await timers.run()
    const staleRecheck = timers.firstId()

    machine.clear(doc, session.generation)
    coordinator.end(doc, session.generation)
    await timers.run(staleRecheck)

    assert.equal(rechecks, 0)
    assert.equal(timers.size, 0)
})

test('page-key replacement invalidates pending work from the obsolete page', async () => {
    const { machine, timers, coordinator } = setUp()
    const doc = {}
    const session = machine.select(doc, 'range-a').session
    let advances = 0
    coordinator.scheduleAdvance({
        owner: doc,
        generation: session.generation,
        pageKey: 'page-1',
        advance: async () => { advances += 1 },
        recheck: () => {},
    })
    const staleTimer = timers.firstId()

    coordinator.replacePage(doc, session.generation, 'page-2')
    await timers.run(staleTimer)

    assert.equal(advances, 0)
    assert.equal(coordinator.snapshot.pageKey, 'page-2')
})

test('relocation after next cancels an obsolete post-next recheck', async () => {
    const { machine, timers, coordinator } = setUp()
    const doc = {}
    const session = machine.select(doc, 'range-a').session
    let rechecks = 0
    coordinator.scheduleAdvance({
        owner: doc,
        generation: session.generation,
        pageKey: 'page-1',
        advance: async () => {},
        recheck: () => { rechecks += 1 },
    })
    await timers.run()
    const staleRecheck = timers.firstId()

    coordinator.replacePage(doc, session.generation, 'page-2')
    await timers.run(staleRecheck)

    assert.equal(rechecks, 0)
    assert.equal(coordinator.snapshot.awaitingRecheckPageKey, null)
})

test('the relocation emitted by an in-flight next preserves one guarded recheck', async () => {
    const { machine, timers, coordinator } = setUp()
    const doc = {}
    const session = machine.select(doc, 'range-a').session
    let resolveAdvance
    const advanceFinished = new Promise(resolve => { resolveAdvance = resolve })
    let rechecks = 0
    coordinator.scheduleAdvance({
        owner: doc,
        generation: session.generation,
        pageKey: 'page-1',
        advance: () => advanceFinished,
        recheck: () => { rechecks += 1 },
    })

    const runningAdvance = timers.run()
    coordinator.replacePage(doc, session.generation, 'page-2')
    resolveAdvance()
    await runningAdvance
    await timers.run()

    assert.equal(rechecks, 1)
    assert.equal(coordinator.snapshot.pageKey, 'page-2')
})

test('range adjustment and auto-page work leave actions hidden', async () => {
    const { machine, timers, coordinator } = setUp()
    const doc = {}
    const session = machine.select(doc, 'range-a').session
    machine.toggleActions(doc, session.generation, 'range-a')

    assert.equal(machine.beginAdjustment(doc).state, SelectionSessionState.selected)
    coordinator.scheduleAdvance({
        owner: doc,
        generation: session.generation,
        pageKey: 'page-1',
        advance: async () => {},
        recheck: () => {},
    })
    await timers.run()
    await timers.run()

    assert.equal(machine.state, SelectionSessionState.selected)
})

test('ending a session cancels pending and post-next state', async () => {
    const { machine, timers, coordinator } = setUp()
    const doc = {}
    const session = machine.select(doc, 'range-a').session
    coordinator.scheduleAdvance({
        owner: doc,
        generation: session.generation,
        pageKey: 'page-1',
        advance: async () => {},
        recheck: () => {},
    })
    await timers.run()
    assert.equal(timers.size, 1)

    machine.clear(doc, session.generation)
    assert.equal(coordinator.end(doc, session.generation), true)
    assert.equal(timers.size, 0)
    assert.equal(coordinator.snapshot.generation, null)
    assert.equal(coordinator.snapshot.pendingPageKey, null)
    assert.equal(coordinator.snapshot.awaitingRecheckPageKey, null)
})

test('owner replacement makes callbacks from a destroyed document harmless', async () => {
    const { machine, timers, coordinator } = setUp()
    const oldDoc = {}
    const newDoc = {}
    const first = machine.select(oldDoc, 'range-a').session
    let advances = 0
    coordinator.scheduleAdvance({
        owner: oldDoc,
        generation: first.generation,
        pageKey: 'page-1',
        advance: async () => { advances += 1 },
        recheck: () => {},
    })
    const staleTimer = timers.firstId()

    const second = machine.select(newDoc, 'range-b').session
    coordinator.observePage(newDoc, second.generation, 'page-1')
    await timers.run(staleTimer)

    assert.equal(advances, 0)
    assert.equal(coordinator.snapshot.owner, newDoc)
})
