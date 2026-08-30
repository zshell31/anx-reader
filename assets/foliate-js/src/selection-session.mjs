export const SelectionSessionState = Object.freeze({
    idle: 'IDLE',
    selected: 'SELECTED',
    actionsVisible: 'ACTIONS_VISIBLE',
})

/**
 * Owns the transient selection interaction state. The owner is normally the
 * content Document; keeping it in the identity check prevents a late event
 * from an old iframe from affecting a selection in a newer one.
 */
export class SelectionSessionMachine {
    #generation = 0
    #active = null

    get state() {
        return this.#active?.state ?? SelectionSessionState.idle
    }

    get current() {
        return this.#active ? { ...this.#active } : null
    }

    select(owner, rangeKey) {
        if (!owner || !rangeKey) throw new TypeError('Selection owner and range key are required')

        if (!this.#active || this.#active.owner !== owner) {
            this.#active = {
                generation: ++this.#generation,
                owner,
                rangeKey,
                state: SelectionSessionState.selected,
            }
            return { kind: 'created', session: this.current, hidActions: false }
        }

        if (this.#active.rangeKey === rangeKey) return null

        const hidActions = this.#active.state === SelectionSessionState.actionsVisible
        this.#active.rangeKey = rangeKey
        this.#active.state = SelectionSessionState.selected
        return { kind: 'changed', session: this.current, hidActions }
    }

    toggleActions(owner, generation, rangeKey) {
        if (!this.matches(owner, generation, rangeKey)) return null

        this.#active.state = this.#active.state === SelectionSessionState.actionsVisible
            ? SelectionSessionState.selected
            : SelectionSessionState.actionsVisible
        return this.current
    }

    hideActions(generation) {
        if (!this.matchesGeneration(generation)) return null
        if (this.#active.state !== SelectionSessionState.actionsVisible) return null
        this.#active.state = SelectionSessionState.selected
        return this.current
    }

    beginAdjustment(owner) {
        if (this.#active?.owner !== owner) return null
        if (this.#active.state !== SelectionSessionState.actionsVisible) return null
        this.#active.state = SelectionSessionState.selected
        return this.current
    }

    clear(owner, generation) {
        if (!this.#active) return null
        if (owner && this.#active.owner !== owner) return null
        if (generation != null && this.#active.generation !== generation) return null

        const ended = this.current
        this.#active = null
        return ended
    }

    matches(owner, generation, rangeKey) {
        return this.#active?.owner === owner
            && this.#active.generation === generation
            && this.#active.rangeKey === rangeKey
    }

    matchesGeneration(generation) {
        return this.#active?.generation === generation
    }

    matchesSession(owner, generation) {
        return this.#active?.owner === owner
            && this.#active.generation === generation
    }
}
