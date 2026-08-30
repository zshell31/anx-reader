const DEFAULT_OPTIONS = Object.freeze({
    advanceDelayMs: 1000,
    recheckInitialDelayMs: 80,
    recheckIntervalMs: 120,
    maxRecheckAttempts: 12,
})

/**
 * Coordinates paginated selection navigation for one Foliate view.
 *
 * SelectionSessionMachine remains the lifetime authority. Every scheduled
 * operation captures its owner and generation, then validates both before it
 * navigates, mutates coordinator state, or asks the owner to recheck selection.
 */
export class AutoPageSelectionCoordinator {
    #machine
    #setTimer
    #clearTimer
    #options
    #scope = null
    #pageKey = null
    #triggeredPages = new Set()
    #pendingWork = null
    #recheckWork = null

    constructor(machine, options = {}) {
        this.#machine = machine
        this.#setTimer = options.setTimer ?? setTimeout
        this.#clearTimer = options.clearTimer ?? clearTimeout
        this.#options = { ...DEFAULT_OPTIONS, ...options }
    }

    get snapshot() {
        return {
            generation: this.#scope?.generation ?? null,
            owner: this.#scope?.owner ?? null,
            pageKey: this.#pageKey,
            pendingPageKey: this.#pendingWork?.pageKey ?? null,
            awaitingRecheckPageKey: this.#recheckWork?.pageKey ?? null,
            recheckAttempts: this.#recheckWork?.attempts ?? 0,
            triggeredPages: new Set(this.#triggeredPages),
        }
    }

    restart(owner, generation) {
        if (!this.#machine.matchesSession(owner, generation)) {
            this.cancelAll()
            return false
        }
        this.#resetWork()
        this.#scope = { owner, generation }
        return true
    }

    observePage(owner, generation, pageKey) {
        if (!this.#machine.matchesSession(owner, generation)) return false

        if (!this.#matchesScope(owner, generation)) {
            this.#resetWork()
            this.#scope = { owner, generation }
        }

        if (this.#pageKey !== pageKey) {
            this.#cancelPending()
            this.#cancelRecheck()
            this.#pageKey = pageKey
        }
        return true
    }

    replacePage(owner, generation, pageKey) {
        if (!this.#matchesScope(owner, generation)
            || !this.#machine.matchesSession(owner, generation)) return false
        if (this.#pageKey === pageKey) return true

        // A relocation emitted by the view.next() already in progress belongs
        // to this generation. A delayed advance that has not started does not.
        if (this.#pendingWork?.timer != null) this.#cancelPending()
        this.#cancelRecheck()
        this.#pageKey = pageKey
        return true
    }

    scheduleAdvance({ owner, generation, pageKey, advance, afterAdvance, recheck }) {
        if (!this.observePage(owner, generation, pageKey)) return false
        if (this.#triggeredPages.has(pageKey)) return false
        if (this.#pendingWork?.pageKey === pageKey) return false

        const work = {
            owner,
            generation,
            pageKey,
            advance,
            afterAdvance,
            recheck,
            timer: null,
        }
        this.#pendingWork = work
        work.timer = this.#setTimer(
            () => this.#runAdvance(work),
            this.#options.advanceDelayMs,
        )
        return true
    }

    cancelPendingPage(owner, generation, pageKey) {
        if (!this.#matchesScope(owner, generation)) return false
        if (this.#pendingWork?.pageKey !== pageKey) return false
        this.#cancelPending()
        return true
    }

    end(owner, generation) {
        if (!this.#matchesScope(owner, generation)) return false
        this.cancelAll()
        return true
    }

    cancelAll() {
        this.#resetWork()
        this.#scope = null
    }

    #matchesScope(owner, generation) {
        return this.#scope?.owner === owner
            && this.#scope.generation === generation
    }

    #isActive(work) {
        return this.#matchesScope(work.owner, work.generation)
            && this.#machine.matchesSession(work.owner, work.generation)
    }

    async #runAdvance(work) {
        if (this.#pendingWork !== work || !this.#isActive(work)) return
        work.timer = null
        this.#triggeredPages.add(work.pageKey)

        let advanced = false
        try {
            await work.advance()
            advanced = true
        } catch (error) {
            console.warn('Could not advance paginated selection', error)
        }

        if (this.#pendingWork !== work || !this.#isActive(work)) return
        if (advanced && work.afterAdvance) {
            try {
                work.afterAdvance()
            } catch (error) {
                console.warn('Could not finish paginated selection advance', error)
            }
        }
        if (this.#pendingWork !== work || !this.#isActive(work)) return
        this.#pendingWork = null
        const recheckWork = { ...work, attempts: 0, timer: null }
        this.#recheckWork = recheckWork
        recheckWork.timer = this.#setTimer(
            () => this.#runRecheck(recheckWork),
            this.#options.recheckInitialDelayMs,
        )
    }

    #runRecheck(work) {
        if (this.#recheckWork !== work || !this.#isActive(work)) return
        work.timer = null
        work.attempts += 1
        work.recheck()

        // The synchronous recheck may observe a replacement page or end the
        // selection. Do not recreate a timer after either invalidation.
        if (this.#recheckWork !== work || !this.#isActive(work)) return
        if (work.attempts >= this.#options.maxRecheckAttempts) {
            this.#recheckWork = null
            return
        }
        work.timer = this.#setTimer(
            () => this.#runRecheck(work),
            this.#options.recheckIntervalMs,
        )
    }

    #cancelPending() {
        const work = this.#pendingWork
        if (work?.timer != null) this.#clearTimer(work.timer)
        this.#pendingWork = null
    }

    #cancelRecheck() {
        const work = this.#recheckWork
        if (work?.timer != null) this.#clearTimer(work.timer)
        this.#recheckWork = null
    }

    #resetWork() {
        this.#cancelPending()
        this.#cancelRecheck()
        this.#pageKey = null
        this.#triggeredPages.clear()
    }
}
